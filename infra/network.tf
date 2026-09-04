# ---------------------------------------------------------------------------
# VPC, subnets, routing.
#
# The load-bearing detail here is what is ABSENT: there is no NAT gateway, and
# the private route tables carry no 0.0.0.0/0 route of any kind. Tasks have no
# route to the internet and the internet has no route to them. Everything the
# task needs at runtime -- pull the image, ship logs -- is reached over
# PrivateLink from inside the VPC (see endpoints.tf).
#
# This is stronger than the usual "private subnets behind a NAT", and it is
# demonstrable in one command rather than argued: describe the route table.
# The application gives up nothing, because it calls nothing -- the model is
# baked into the image and there are no external dependencies at request time.
# ---------------------------------------------------------------------------

data "aws_availability_zones" "available" {
  state = "available"

  # Local Zones and Wavelength Zones surface here too and do not run Fargate.
  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

locals {
  name = "${var.project}-${var.environment}"
  azs  = slice(data.aws_availability_zones.available.names, 0, var.az_count)
}

resource "aws_vpc" "main" {
  cidr_block = var.vpc_cidr

  # Both are required for the interface endpoints' private DNS to work. With
  # enable_dns_hostnames off, private_dns_enabled on an endpoint is rejected,
  # and the SDK keeps resolving the public ECR/Logs names -- which, with no
  # internet route, means the traffic goes nowhere and the task dies on pull.
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = local.name }
}

# --- Public tier: the ALB only ---------------------------------------------

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = local.name }
}

resource "aws_subnet" "public" {
  count = var.az_count

  vpc_id            = aws_vpc.main.id
  availability_zone = local.azs[count.index]
  cidr_block        = cidrsubnet(var.vpc_cidr, 4, count.index)

  # The ALB nodes live here and need public addressing; nothing else does.
  map_public_ip_on_launch = false

  tags = {
    Name = "${local.name}-public-${local.azs[count.index]}"
    Tier = "public"
  }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${local.name}-public" }
}

resource "aws_route" "public_internet" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.main.id
}

resource "aws_route_table_association" "public" {
  count = var.az_count

  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# --- Private tier: the Fargate tasks ---------------------------------------

resource "aws_subnet" "private" {
  count = var.az_count

  vpc_id            = aws_vpc.main.id
  availability_zone = local.azs[count.index]
  cidr_block        = cidrsubnet(var.vpc_cidr, 4, count.index + 8)

  tags = {
    Name = "${local.name}-private-${local.azs[count.index]}"
    Tier = "private"
  }
}

# One route table per AZ rather than one shared table. It costs nothing, and it
# keeps the blast radius of any future per-AZ route (a NAT, a TGW attachment)
# to a single zone instead of silently applying it to both.
#
# Note what is not here: no aws_route resource targets these tables except the
# S3 gateway endpoint in endpoints.tf, which adds a prefix-list route to S3 and
# nothing else. There is no default route.
resource "aws_route_table" "private" {
  count = var.az_count

  vpc_id = aws_vpc.main.id
  tags   = { Name = "${local.name}-private-${local.azs[count.index]}" }
}

resource "aws_route_table_association" "private" {
  count = var.az_count

  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private[count.index].id
}
