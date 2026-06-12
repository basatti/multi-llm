# Single VPC, three tiers of private subnets (architecture.md §8):
#   app      — existing product services
#   platform — gateway + orchestration + Redis, behind internal LBs
#   gpu      — vLLM nodes; ingress only from the gateway SG
# One public subnet exists solely for NAT egress. No public ingress anywhere.

data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  azs = slice(data.aws_availability_zones.available.names, 0, var.az_count)
}

resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "llm-platform-${var.env}"
  }
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id

  tags = {
    Name = "llm-platform-${var.env}"
  }
}

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.this.id
  cidr_block              = cidrsubnet(var.vpc_cidr, 8, 0)
  availability_zone       = local.azs[0]
  map_public_ip_on_launch = true

  tags = {
    Name = "llm-platform-${var.env}-public-nat"
  }
}

resource "aws_subnet" "app" {
  count             = var.az_count
  vpc_id            = aws_vpc.this.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 8, 10 + count.index)
  availability_zone = local.azs[count.index]

  tags = {
    Name = "llm-platform-${var.env}-app-${count.index}"
    Tier = "app"
  }
}

resource "aws_subnet" "platform" {
  count             = var.az_count
  vpc_id            = aws_vpc.this.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 8, 20 + count.index)
  availability_zone = local.azs[count.index]

  tags = {
    Name = "llm-platform-${var.env}-platform-${count.index}"
    Tier = "platform"
  }
}

resource "aws_subnet" "gpu" {
  count             = var.az_count
  vpc_id            = aws_vpc.this.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 8, 30 + count.index)
  availability_zone = local.azs[count.index]

  tags = {
    Name = "llm-platform-${var.env}-gpu-${count.index}"
    Tier = "gpu"
  }
}

resource "aws_eip" "nat" {
  domain = "vpc"
}

resource "aws_nat_gateway" "this" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public.id

  tags = {
    Name = "llm-platform-${var.env}"
  }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.this.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.this.id
  }
}

resource "aws_route_table_association" "app" {
  count          = var.az_count
  subnet_id      = aws_subnet.app[count.index].id
  route_table_id = aws_route_table.private.id
}

resource "aws_route_table_association" "platform" {
  count          = var.az_count
  subnet_id      = aws_subnet.platform[count.index].id
  route_table_id = aws_route_table.private.id
}

resource "aws_route_table_association" "gpu" {
  count          = var.az_count
  subnet_id      = aws_subnet.gpu[count.index].id
  route_table_id = aws_route_table.private.id
}

# ── Security groups ──────────────────────────────────────────────────────────

resource "aws_security_group" "alb" {
  name        = "llm-gateway-alb-${var.env}"
  description = "Internal ALB in front of the gateway"
  vpc_id      = aws_vpc.this.id

  ingress {
    description = "Gateway ingress from inside the VPC only"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "gateway" {
  name        = "llm-gateway-service-${var.env}"
  description = "Gateway (LiteLLM) tasks"
  vpc_id      = aws_vpc.this.id

  ingress {
    description     = "From the internal ALB only"
    from_port       = 4000
    to_port         = 4000
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  # TODO(§5.2): lock egress down to declared provider endpoints + vLLM service
  # once those endpoints are enumerated. Wide-open egress is a Phase 0 interim.
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "gpu" {
  name        = "llm-inference-${var.env}"
  description = "vLLM nodes: ingress ONLY from the gateway (architecture.md section 8)"
  vpc_id      = aws_vpc.this.id

  ingress {
    description     = "OpenAI-compatible serving port, gateway only"
    from_port       = 8000
    to_port         = 8000
    protocol        = "tcp"
    security_groups = [aws_security_group.gateway.id]
  }

  # TODO(§8): restrict egress to S3 (weights) and telemetry via VPC endpoints.
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}
