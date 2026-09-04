# ---------------------------------------------------------------------------
# CodeDeploy blue/green for ECS.
#
# What this buys, concretely: a deployment stands up a complete second task set
# on production-identical infrastructure, health-checks it behind the test
# listener, shifts production traffic to it in one step, then keeps the old
# task set alive for a bake window. If the alarms trip during that window, the
# traffic shifts BACK -- to tasks that are already running and already warm, so
# the rollback is a load-balancer operation rather than a fresh deployment.
#
# It is also the reason the alarms are load-bearing rather than decorative, and
# the reason there is no separate staging environment: the green task set is a
# pre-production deployment on production infrastructure, which is strictly
# more faithful than a second, smaller stack would be.
#
# CodeDeploy for ECS carries no charge, and the second target group is free.
# ---------------------------------------------------------------------------

resource "aws_codedeploy_app" "app" {
  name             = local.name
  compute_platform = "ECS"

  tags = { Name = local.name }
}

resource "aws_codedeploy_deployment_group" "app" {
  app_name               = aws_codedeploy_app.app.name
  deployment_group_name  = "${local.name}-dg"
  service_role_arn       = aws_iam_role.codedeploy.arn
  deployment_config_name = var.deployment_config_name

  deployment_style {
    deployment_option = "WITH_TRAFFIC_CONTROL"
    deployment_type   = "BLUE_GREEN"
  }

  ecs_service {
    cluster_name = aws_ecs_cluster.main.name
    service_name = aws_ecs_service.app.name
  }

  blue_green_deployment_config {
    deployment_ready_option {
      # CONTINUE_DEPLOYMENT shifts traffic as soon as the replacement task set
      # is healthy. STOP_DEPLOYMENT holds at the gate for a human to approve --
      # the right choice for a real production change process, and the wrong
      # one for a stack that has to demonstrate itself unattended.
      #
      # The two are derived from one variable rather than set independently
      # because CodeDeploy only honours a wait time under STOP_DEPLOYMENT; a
      # wait time paired with CONTINUE_DEPLOYMENT is silently meaningless, so
      # asking for a wait is what selects the mode that can provide one.
      action_on_timeout    = var.deployment_ready_wait_minutes > 0 ? "STOP_DEPLOYMENT" : "CONTINUE_DEPLOYMENT"
      wait_time_in_minutes = var.deployment_ready_wait_minutes
    }

    terminate_blue_instances_on_deployment_success {
      action = "TERMINATE"
      # The bake window. Both task sets are alive for this long after the
      # shift, so rollback is a traffic move rather than a redeploy -- and so
      # there is a real interval in which to observe both.
      termination_wait_time_in_minutes = var.blue_termination_wait_minutes
    }
  }

  auto_rollback_configuration {
    enabled = true
    events = [
      # The replacement task set never went healthy, or the deployment errored.
      "DEPLOYMENT_FAILURE",
      # A wired alarm fired during the deployment or its bake window.
      "DEPLOYMENT_STOP_ON_ALARM",
    ]
  }

  alarm_configuration {
    enabled = true
    alarms = [
      aws_cloudwatch_metric_alarm.target_5xx.alarm_name,
      aws_cloudwatch_metric_alarm.p99_latency.alarm_name,
    ]

    # If CodeDeploy cannot read an alarm's state, treat that as a reason to
    # stop rather than a reason to proceed blind. Both alarms are configured
    # treat_missing_data = notBreaching, so an idle load balancer does not
    # produce a spurious stop here.
    ignore_poll_alarm_failure = false
  }

  load_balancer_info {
    target_group_pair_info {
      prod_traffic_route {
        listener_arns = [aws_lb_listener.production.arn]
      }

      test_traffic_route {
        listener_arns = [aws_lb_listener.test.arn]
      }

      # Order is not significant -- CodeDeploy discovers which group is
      # currently serving production and uses the other one for the
      # replacement task set. The names simply have to match the two groups
      # attached to the listeners above.
      target_group {
        name = aws_lb_target_group.blue.name
      }

      target_group {
        name = aws_lb_target_group.green.name
      }
    }
  }

  tags = { Name = "${local.name}-dg" }
}
