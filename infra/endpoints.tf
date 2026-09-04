# ---------------------------------------------------------------------------
# VPC endpoints -- what replaces the NAT gateway.
#
# Four endpoints, and the fourth is the one that gets forgotten:
#
#   ecr.api   interface   ECR authentication and metadata
#   ecr.dkr   interface   the Docker registry protocol itself
#   logs      interface   CloudWatch Logs, for the awslogs driver
#   s3        GATEWAY     ECR image LAYERS are stored in S3
#
# Omit the S3 gateway endpoint and the failure is maddening rather than
# obvious: ecr.api and ecr.dkr resolve, authentication succeeds, the manifest
# is fetched -- and then the pull hangs and the task dies, because the layers
# themselves are served out of S3. It is free, and unlike the other three it
# attaches to route tables rather than to subnets.
#
# Not needed: an endpoint for the ECS control plane. On Fargate platform 1.4.0
# the agent's control-plane traffic is carried on AWS-managed infrastructure
# outside the customer VPC; only image pulls and log delivery traverse the task
# ENI. (ssm/ssmmessages would be needed for ECS Exec, which this stack does not
# enable.)
#
# Cost honesty: interface endpoints bill PER AZ, so 3 x 2 = 6 ENIs at about
# $0.01/hr is ~$0.06/hr against a single NAT gateway's $0.045/hr. This is more
# expensive, not a wash -- roughly +$11/month to remove internet egress
# entirely.
# ---------------------------------------------------------------------------

locals {
  interface_endpoints = {
    ecr_api = "ecr.api"
    ecr_dkr = "ecr.dkr"
    logs    = "logs"
  }
}

resource "aws_vpc_endpoint" "interface" {
  for_each = local.interface_endpoints

  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.${data.aws_region.current.region}.${each.value}"
  vpc_endpoint_type = "Interface"

  subnet_ids         = aws_subnet.private[*].id
  security_group_ids = [aws_security_group.endpoint.id]

  # Without this the endpoint gets only its own long regional DNS name, the SDK
  # keeps resolving api.ecr.<region>.amazonaws.com to a public IP, and -- with
  # no default route out of the private subnets -- the packets are dropped.
  # This is the second of the two classic "task hangs on launch" causes.
  private_dns_enabled = true

  tags = { Name = "${local.name}-${each.key}" }
}

# Gateway endpoint. Free, and attached to route tables: each private route
# table gains a prefix-list route for S3 and nothing else.
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.${data.aws_region.current.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = aws_route_table.private[*].id

  tags = { Name = "${local.name}-s3" }
}
