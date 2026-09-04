# ---------------------------------------------------------------------------
# ECS cluster, task definition, service.
# ---------------------------------------------------------------------------

resource "aws_ecs_cluster" "main" {
  name = local.name

  setting {
    name  = "containerInsights"
    value = var.container_insights ? "enabled" : "disabled"
  }

  tags = { Name = local.name }
}

resource "aws_ecs_cluster_capacity_providers" "main" {
  cluster_name       = aws_ecs_cluster.main.name
  capacity_providers = ["FARGATE"]

  default_capacity_provider_strategy {
    capacity_provider = "FARGATE"
    weight            = 1
  }
}

# ---------------------------------------------------------------------------
# Task definition.
#
# Terraform registers revision 1 and then stops caring. Every subsequent
# revision is registered by the deploy workflow with a git-SHA-tagged image and
# handed to ECS; Terraform's copy stays at the bootstrap tag on purpose,
# which is why the service ignores task_definition below.
# ---------------------------------------------------------------------------

resource "aws_ecs_task_definition" "app" {
  family                   = local.name
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.task_cpu
  memory                   = var.task_memory
  execution_role_arn       = aws_iam_role.task_execution.arn
  task_role_arn            = aws_iam_role.task.arn

  # Explicit rather than inherited. The image is built on GitHub's x86 runners
  # and never on the arm64 laptop, so pinning the architecture here makes a
  # mismatched push fail at task launch with a clear error instead of an
  # opaque exec-format failure inside the container.
  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }

  container_definitions = jsonencode([
    {
      name      = var.container_name
      image     = "${aws_ecr_repository.app.repository_url}:${var.image_tag}"
      essential = true

      portMappings = [
        {
          containerPort = var.container_port
          protocol      = "tcp"
        }
      ]

      environment = [
        { name = "WORKERS", value = tostring(var.uvicorn_workers) },
        { name = "ORT_INTRA_OP_THREADS", value = "1" },
      ]

      # ECS ignores the image's own HEALTHCHECK instruction, so it is restated
      # here. Same command as the Dockerfile: python:*-slim has no curl, and
      # adding one purely for a health check would put a package into the
      # runtime image.
      healthCheck = {
        command     = ["CMD-SHELL", "python -c \"import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:${var.container_port}/health', timeout=2).status==200 else 1)\""]
        interval    = 30
        timeout     = 5
        retries     = 3
        startPeriod = 30
      }

      # Time for uvicorn to finish in-flight requests after SIGTERM. The CMD's
      # `exec` is what makes this meaningful -- it puts uvicorn at PID 1 so the
      # signal reaches it rather than a shell that ignores it.
      stopTimeout = 30

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.app.name
          "awslogs-region"        = data.aws_region.current.region
          "awslogs-stream-prefix" = "ecs"
        }
      }
    }
  ])

  tags = { Name = local.name }
}

# ---------------------------------------------------------------------------
# Service.
# ---------------------------------------------------------------------------

resource "aws_ecs_service" "app" {
  name            = local.name
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.app.arn
  launch_type     = "FARGATE"

  # Zero on the first apply: the bootstrap image tag does not exist yet, and a
  # service at desired_count = 2 would spend the gap between apply and the
  # first workflow run churning task launches that can never pull. See the
  # `bootstrap` variable.
  desired_count = var.bootstrap ? 0 : var.desired_count

  # Pinned rather than LATEST. 1.4.0 is the platform version whose networking
  # model this endpoint set assumes: image pulls and log delivery traverse the
  # task ENI, control-plane traffic does not.
  platform_version = "1.4.0"

  # ECS's own deployment controller, running ECS-NATIVE blue/green. The
  # original design used CodeDeploy; this account cannot subscribe to that
  # service, and the native implementation turns out to be the better answer
  # anyway -- same canary, same bake, same alarm-driven rollback, minus a
  # service role, an appspec file, and an ownership fight.
  deployment_controller {
    type = "ECS"
  }

  deployment_configuration {
    strategy = var.deployment_strategy

    # The observation window. After the full shift the original task set stays
    # running for this long, so a rollback is a traffic move onto tasks that
    # are already warm rather than a fresh deployment.
    bake_time_in_minutes = var.bake_time_in_minutes

    # Only valid on the CANARY strategy -- the API rejects it on BLUE_GREEN.
    dynamic "canary_configuration" {
      for_each = var.deployment_strategy == "CANARY" ? [1] : []

      content {
        canary_percent              = var.canary_percent
        canary_bake_time_in_minutes = var.canary_bake_time_in_minutes
      }
    }
  }

  # What makes the alarms load-bearing rather than decorative: if either
  # breaches while a deployment is in flight, ECS shifts traffic back on its
  # own. Same two alarms and the same LoadBalancer dimension as before -- see
  # observability.tf for why UnHealthyHostCount is deliberately not here.
  alarms {
    alarm_names = [
      aws_cloudwatch_metric_alarm.target_5xx.alarm_name,
      aws_cloudwatch_metric_alarm.p99_latency.alarm_name,
    ]
    enable   = true
    rollback = true
  }

  network_configuration {
    subnets         = aws_subnet.private[*].id
    security_groups = [aws_security_group.task.id]

    # No public IP, and -- see network.tf -- no route to the internet either.
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.blue.arn
    container_name   = var.container_name
    container_port   = var.container_port

    # The blue/green wiring. ECS needs both target groups and the listener
    # rules that point at them, because the traffic shift IS a rewrite of those
    # rules -- weighted across both groups during the canary, then fully onto
    # the replacement.
    #
    # role_arn is the infrastructure role ECS assumes to perform that rewrite.
    # Without it ECS cannot modify the load balancer and the deployment fails
    # before a single task starts.
    # Required for both two-task-set strategies; meaningless for ROLLING,
    # which replaces tasks in place and never needs a second target group.
    dynamic "advanced_configuration" {
      for_each = var.deployment_strategy == "ROLLING" ? [] : [1]

      content {
        alternate_target_group_arn = aws_lb_target_group.green.arn
        production_listener_rule   = aws_lb_listener_rule.production.arn
        test_listener_rule         = aws_lb_listener_rule.test.arn
        role_arn                   = aws_iam_role.ecs_infrastructure.arn
      }
    }
  }

  # Long enough for the ORT session to construct. Set too low, ECS kills tasks
  # that were merely still loading and the service never reaches steady state.
  health_check_grace_period_seconds = var.health_check_grace_period_seconds

  propagate_tags = "SERVICE"

  # Teardown is a deliverable here, not an afterthought. A CODE_DEPLOY-managed
  # service can be left holding a task set from an in-flight deployment that
  # Terraform has never seen, and DeleteService refuses while it runs -- so a
  # destroy stalls on the one resource that gates the ALB and the endpoints,
  # which are the two lines that actually accrue cost.
  force_delete = true

  # Ownership boundaries. Three attributes of this service are set by
  # something other than Terraform, and each would otherwise show up as a
  # permanent diff that is destructive to apply:
  #
  #   task_definition   the deploy workflow registers a new SHA-tagged revision
  #                     on every push; Terraform still holds revision 1 with the
  #                     bootstrap image tag
  #   desired_count     Application Auto Scaling sets it; Terraform would drag
  #                     it back to the floor on every apply
  #
  # load_balancer is deliberately NOT ignored, and that is a change from the
  # CodeDeploy design. CodeDeploy rewrote the service's load-balancer config on
  # every deployment, so Terraform had to look away. ECS-native blue/green does
  # not: the service declares both target groups once, and the traffic shift is
  # a rewrite of the LISTENER RULES instead (which is why those carry the
  # ignore_changes now -- see alb.tf).
  #
  # Ignoring it here is not merely unnecessary but actively breaks the stack:
  # advanced_configuration lives inside this block, so an ignored
  # load_balancer means the blue/green wiring is never sent, and UpdateService
  # fails with "advancedConfiguration field is required for all loadBalancers
  # when using the Blue/green deployment strategy".
  lifecycle {
    ignore_changes = [task_definition, desired_count]
  }

  # The listeners must exist before the service registers with the target
  # group, otherwise the ALB association races.
  depends_on = [
    aws_lb_listener_rule.production,
    aws_lb_listener_rule.test,
    aws_iam_role_policy_attachment.ecs_infrastructure,
  ]

  tags = { Name = local.name }
}
