# ---------------------------------------------------------------------------
# Load balancer, two target groups, two listeners.
#
# The pair of target groups is what makes blue/green possible: CodeDeploy needs
# somewhere to stand up the replacement task set and health-check it before any
# production traffic moves. Both are created equal -- "blue" and "green" are
# roles that swap on every deployment, not fixed identities. After the first
# deployment the production listener points at green; after the second, back at
# blue.
# ---------------------------------------------------------------------------

resource "aws_lb" "main" {
  name               = local.name
  load_balancer_type = "application"
  internal           = false
  subnets            = aws_subnet.public[*].id
  security_groups    = [aws_security_group.alb.id]

  # Rejects requests with malformed headers rather than passing them to the
  # application to interpret -- cheap request-smuggling hygiene.
  drop_invalid_header_fields = true

  # This stack is meant to be destroyed after evidence capture.
  enable_deletion_protection = false

  idle_timeout = 60

  # Answers "how would you investigate a bad request after the fact" with a
  # bucket rather than a shrug. Costs pennies at this volume, and it is the only
  # per-request record that survives a task being replaced -- application logs
  # go with the task set, access logs do not.
  dynamic "access_logs" {
    for_each = var.enable_alb_access_logs ? [1] : []
    content {
      bucket  = aws_s3_bucket.alb_logs[0].id
      prefix  = local.name
      enabled = true
    }
  }

  # The ALB validates that it can write to the bucket AT CREATION TIME, so the
  # policy has to be in place first. Without this the apply fails with
  # "Access Denied for bucket" and nothing about the message points at ordering.
  depends_on = [aws_s3_bucket_policy.alb_logs]

  tags = { Name = local.name }
}

resource "aws_lb_target_group" "blue" {
  name     = "${local.name}-blue"
  port     = var.container_port
  protocol = "HTTP"
  vpc_id   = aws_vpc.main.id

  # "ip", not "instance". awsvpc networking gives each task its own ENI and its
  # own private address; there is no container-instance port to register, and
  # "instance" simply cannot express a Fargate target. This is the single most
  # common target-group mistake on Fargate.
  target_type = "ip"

  # The default 300s means every deployment spends five minutes draining tasks
  # that finished serving long before.
  deregistration_delay = var.deregistration_delay

  health_check {
    path                = var.health_check_path
    protocol            = "HTTP"
    matcher             = "200"
    interval            = 15
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }

  tags = { Name = "${local.name}-blue" }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_lb_target_group" "green" {
  name        = "${local.name}-green"
  port        = var.container_port
  protocol    = "HTTP"
  vpc_id      = aws_vpc.main.id
  target_type = "ip"

  deregistration_delay = var.deregistration_delay

  health_check {
    path                = var.health_check_path
    protocol            = "HTTP"
    matcher             = "200"
    interval            = 15
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }

  tags = { Name = "${local.name}-green" }

  lifecycle {
    create_before_destroy = true
  }
}

# --- Listeners --------------------------------------------------------------
#
# HTTPS is a known gap, not an oversight: ACM needs a domain to validate
# against and this project has none. Adding it later is a certificate ARN, a
# :443 listener with ssl_policy, and redirecting this listener to it -- the
# structure below does not change.

resource "aws_lb_listener" "production" {
  load_balancer_arn = aws_lb.main.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.blue.arn
  }

  # CodeDeploy REWRITES this default action on every deployment -- that swap is
  # the traffic shift. Without ignore_changes, the next `terraform plan` after
  # any deployment proposes reverting production traffic to the old target
  # group, which is both a permanent diff and an outage waiting to be applied.
  lifecycle {
    ignore_changes = [default_action]
  }

  tags = { Name = "${local.name}-production" }
}

resource "aws_lb_listener" "test" {
  load_balancer_arn = aws_lb.main.arn
  port              = var.test_listener_port
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.green.arn
  }

  lifecycle {
    ignore_changes = [default_action]
  }

  tags = { Name = "${local.name}-test" }
}
