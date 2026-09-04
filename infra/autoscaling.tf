# ---------------------------------------------------------------------------
# Application Auto Scaling on the ECS service.
#
# CPU target tracking, deliberately, rather than ALBRequestCountPerTarget.
# Request-count tracking reads better on paper, but its resource_label has to
# name a SPECIFIC target group -- and under blue/green the production target
# group swaps on every deployment, so the policy would be pointing at the idle
# group half the time and scaling on a metric that had gone to zero. CPU has no
# coupling to the deployment mechanism at all.
# ---------------------------------------------------------------------------

# Not created during bootstrap: min_capacity is enforced, so an autoscaling
# target would immediately drag the deliberately-empty service back up to two
# tasks that have no image to pull. On the second apply it appears, and raising
# the service to its floor is precisely its job -- desired_count is in the
# service's ignore_changes list, so nothing else would.
resource "aws_appautoscaling_target" "ecs" {
  count = var.bootstrap ? 0 : 1

  service_namespace  = "ecs"
  resource_id        = "service/${aws_ecs_cluster.main.name}/${aws_ecs_service.app.name}"
  scalable_dimension = "ecs:service:DesiredCount"

  min_capacity = var.min_capacity
  max_capacity = var.max_capacity
}

resource "aws_appautoscaling_policy" "cpu" {
  count = var.bootstrap ? 0 : 1

  name               = "${local.name}-cpu-target-tracking"
  policy_type        = "TargetTrackingScaling"
  service_namespace  = aws_appautoscaling_target.ecs[0].service_namespace
  resource_id        = aws_appautoscaling_target.ecs[0].resource_id
  scalable_dimension = aws_appautoscaling_target.ecs[0].scalable_dimension

  target_tracking_scaling_policy_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }

    # Placeholder until per-task Fargate capacity is measured. Local numbers
    # (4,120 RPS on an M1, 2 uvicorn workers) will not transfer to 0.5 vCPU on
    # amd64; the setpoint follows the measurement rather than preceding it.
    target_value = var.cpu_target_utilization

    # Asymmetric on purpose: add capacity readily, remove it reluctantly. A
    # too-eager scale-in is what turns a traffic dip into a cold-start storm
    # when the traffic returns.
    scale_out_cooldown = var.scale_out_cooldown
    scale_in_cooldown  = var.scale_in_cooldown

    disable_scale_in = false
  }
}
