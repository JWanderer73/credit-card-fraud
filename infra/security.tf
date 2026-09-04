# ---------------------------------------------------------------------------
# Security groups -- the "strict security groups" claim, built precisely.
#
#   alb_sg       ingress :80 from the internet          (the ONE CIDR rule)
#                egress  :8000 -> task_sg
#   task_sg      ingress :8000 <- alb_sg                (by SG id, not CIDR)
#                egress  :443  -> endpoint_sg
#                egress  :443  -> the S3 prefix list    (image layers)
#   endpoint_sg  ingress :443  <- task_sg
#
# Every rule in the mesh references another security group BY ID. The single
# CIDR-based rule in the stack is the ALB's :80 from 0.0.0.0/0, which is the one
# place it belongs. That is the point: "unreachable except through the ALB"
# becomes a structural property of the graph rather than an arithmetic claim
# about subnet ranges, and it stays true if the subnets are ever renumbered.
#
# No SSH anywhere. No 0.0.0.0/0 ingress on tasks. assign_public_ip = false.
#
# Modern per-rule resources (aws_vpc_security_group_{ingress,egress}_rule) are
# used rather than inline ingress/egress blocks: inline blocks own the entire
# rule set of the group and thrash against anything that touches it
# out-of-band, and they cannot be individually addressed in state.
# ---------------------------------------------------------------------------

# Note on the bare group resources: Terraform revokes the default allow-all
# egress rule that AWS attaches at creation time whenever no inline egress block
# is present. Every rule below is therefore the complete, declared truth.

resource "aws_security_group" "alb" {
  name        = "${local.name}-alb"
  description = "Public entry point. The only group with an internet-facing rule."
  vpc_id      = aws_vpc.main.id

  tags = { Name = "${local.name}-alb" }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_security_group" "task" {
  name        = "${local.name}-task"
  description = "Fargate tasks. Reachable only from the ALB; can reach only the VPC endpoints."
  vpc_id      = aws_vpc.main.id

  tags = { Name = "${local.name}-task" }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_security_group" "endpoint" {
  name        = "${local.name}-endpoint"
  description = "Interface VPC endpoint ENIs. Reachable only from the tasks."
  vpc_id      = aws_vpc.main.id

  tags = { Name = "${local.name}-endpoint" }

  lifecycle {
    create_before_destroy = true
  }
}

# --- alb_sg -----------------------------------------------------------------

resource "aws_vpc_security_group_ingress_rule" "alb_http" {
  security_group_id = aws_security_group.alb.id
  description       = "HTTP from the internet"

  cidr_ipv4   = "0.0.0.0/0"
  ip_protocol = "tcp"
  from_port   = 80
  to_port     = 80
}

# The blue/green test listener. Closed by default -- ECS never connects to it,
# it only re-points its rule at the replacement target group, so leaving :8080
# open to the world would add a second internet-facing entry point for no
# functional gain. Populate test_listener_allowed_cidrs to hand-validate a
# replacement task set before it takes production traffic.
resource "aws_vpc_security_group_ingress_rule" "alb_test" {
  count = length(var.test_listener_allowed_cidrs)

  security_group_id = aws_security_group.alb.id
  description       = "Blue/green test listener, restricted"

  cidr_ipv4   = var.test_listener_allowed_cidrs[count.index]
  ip_protocol = "tcp"
  from_port   = var.test_listener_port
  to_port     = var.test_listener_port
}

resource "aws_vpc_security_group_egress_rule" "alb_to_tasks" {
  security_group_id = aws_security_group.alb.id
  description       = "Health checks and forwarded requests to the tasks"

  referenced_security_group_id = aws_security_group.task.id
  ip_protocol                  = "tcp"
  from_port                    = var.container_port
  to_port                      = var.container_port
}

# --- task_sg ----------------------------------------------------------------

resource "aws_vpc_security_group_ingress_rule" "task_from_alb" {
  security_group_id = aws_security_group.task.id
  description       = "Application traffic from the ALB only"

  # By security-group ID. Never a CIDR: a CIDR rule would admit anything that
  # happened to hold an address in the range, and would silently rot if the
  # subnets were ever renumbered.
  referenced_security_group_id = aws_security_group.alb.id
  ip_protocol                  = "tcp"
  from_port                    = var.container_port
  to_port                      = var.container_port
}

resource "aws_vpc_security_group_egress_rule" "task_to_endpoints" {
  security_group_id = aws_security_group.task.id
  description       = "HTTPS to the interface VPC endpoints (ECR API/DKR, CloudWatch Logs)"

  referenced_security_group_id = aws_security_group.endpoint.id
  ip_protocol                  = "tcp"
  from_port                    = 443
  to_port                      = 443
}

# The trap that pairs with the S3 gateway endpoint. A gateway endpoint is a
# ROUTE, not an ENI, so its traffic is not covered by the egress rule above --
# it leaves the task towards S3's public address range and needs its own
# allowance. Restricting egress to endpoint_sg alone therefore produces exactly
# the failure the S3 endpoint was added to prevent: auth succeeds, layers hang.
#
# The prefix list is AWS-managed and region-specific; taking its id off the
# gateway endpoint keeps it correct without a hard-coded pl-* value.
resource "aws_vpc_security_group_egress_rule" "task_to_s3" {
  security_group_id = aws_security_group.task.id
  description       = "HTTPS to S3 via the gateway endpoint -- ECR image layers"

  prefix_list_id = aws_vpc_endpoint.s3.prefix_list_id
  ip_protocol    = "tcp"
  from_port      = 443
  to_port        = 443
}

# --- endpoint_sg ------------------------------------------------------------

resource "aws_vpc_security_group_ingress_rule" "endpoint_from_tasks" {
  security_group_id = aws_security_group.endpoint.id
  description       = "HTTPS from the tasks only"

  referenced_security_group_id = aws_security_group.task.id
  ip_protocol                  = "tcp"
  from_port                    = 443
  to_port                      = 443
}

# endpoint_sg deliberately has no egress rules at all. Security groups are
# stateful, so replies to allowed inbound connections flow regardless; an
# endpoint ENI never originates a connection.
