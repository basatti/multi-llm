# Production deploy — single-GPU shape with prod-grade plumbing and
# cost-aware scheduling. This is the env you point real apps at.
#
# Topology:
#   ALB (TLS, *.kleem.io) → EC2 g4dn.xlarge running the full compose stack
#   (vLLM + LiteLLM gateway + Postgres + Redis + Langfuse + orchestration).
#   Route53 A-alias: llm.kleem.io → ALB.
#
# Cost-aware scheduling (EventBridge Scheduler):
#   Stop at 22:00 IST weekdays; start at 08:00 IST weekdays; stays stopped all
#   weekend. Set var.enable_schedule = false to keep the box up 24/7. EBS
#   preserves model cache + db + traces across stop/start so wake is ~1 minute.
#
# Departures from the layered architecture in docs/architecture.md (sandbox
# tier; document as Phase 0 single-box, untangled when traffic justifies it):
#   - Gateway, orchestration, and inference colocated on one VM.
#   - Single AZ for the instance (ALB is multi-AZ).
#   - Orchestration is not exposed publicly through the ALB; only the gateway
#     (use SSM Session Manager to reach :8000 for management).

terraform {
  required_version = ">= 1.7"
  required_providers {
    aws    = { source = "hashicorp/aws", version = "~> 5.60" }
    random = { source = "hashicorp/random", version = "~> 3.6" }
  }
}

provider "aws" {
  region = var.region
  default_tags {
    tags = {
      Project     = "llm-platform"
      Environment = "prod"
      ManagedBy   = "terraform"
    }
  }
}

data "aws_caller_identity" "current" {}
data "aws_availability_zones" "available" { state = "available" }

# Existing kleem.io zone + *.kleem.io cert in ap-south-1.
data "aws_route53_zone" "kleem" {
  name         = "kleem.io."
  private_zone = false
}

data "aws_acm_certificate" "kleem" {
  domain      = "*.kleem.io"
  most_recent = true
  statuses    = ["ISSUED"]
}

# ── networking ───────────────────────────────────────────────────────────────

resource "aws_vpc" "this" {
  cidr_block           = "10.50.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = "llm-platform" }
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = "llm-platform" }
}

# Two public subnets in different AZs — ALB needs ≥2; instance lives in the first.
resource "aws_subnet" "public" {
  count                   = 2
  vpc_id                  = aws_vpc.this.id
  cidr_block              = cidrsubnet(aws_vpc.this.cidr_block, 8, count.index)
  availability_zone       = data.aws_availability_zones.available.names[count.index]
  map_public_ip_on_launch = true
  tags                    = { Name = "llm-platform-public-${count.index}" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }
}

resource "aws_route_table_association" "public" {
  count          = 2
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# ── security groups ─────────────────────────────────────────────────────────

resource "aws_security_group" "alb" {
  name        = "llm-platform-alb"
  description = "ALB for the gateway"
  vpc_id      = aws_vpc.this.id
  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "instance" {
  name        = "llm-platform-instance"
  description = "GPU instance: gateway ingress from ALB only"
  vpc_id      = aws_vpc.this.id
  ingress {
    description     = "Gateway from ALB"
    from_port       = 4000
    to_port         = 4000
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# ── secrets in SSM (cheaper than Secrets Manager at this scale) ─────────────

resource "random_password" "litellm_master_key" {
  length  = 32
  special = false
}
resource "random_password" "postgres_password" {
  length  = 24
  special = false
}
resource "random_password" "langfuse_public_key" {
  length  = 24
  special = false
}
resource "random_password" "langfuse_secret_key" {
  length  = 40
  special = false
}
resource "random_password" "langfuse_salt" {
  length  = 32
  special = false
}
resource "random_password" "langfuse_encryption_key" {
  length  = 32
  special = false
}
resource "random_password" "langfuse_nextauth_secret" {
  length  = 32
  special = false
}
resource "random_password" "langfuse_init_user_password" {
  length  = 20
  special = false
}
resource "random_password" "clickhouse_password" {
  length  = 24
  special = false
}
resource "random_password" "minio_root_password" {
  length  = 24
  special = false
}

locals {
  secret_map = {
    "litellm-master-key"          = random_password.litellm_master_key.result
    "postgres-password"           = random_password.postgres_password.result
    "langfuse-public-key"         = "pk-lf-${random_password.langfuse_public_key.result}"
    "langfuse-secret-key"         = "sk-lf-${random_password.langfuse_secret_key.result}"
    "langfuse-salt"               = random_password.langfuse_salt.result
    "langfuse-encryption-key"     = random_password.langfuse_encryption_key.result
    "langfuse-nextauth-secret"    = random_password.langfuse_nextauth_secret.result
    "langfuse-init-user-password" = random_password.langfuse_init_user_password.result
    "clickhouse-password"         = random_password.clickhouse_password.result
    "minio-root-password"         = random_password.minio_root_password.result
  }
}

resource "aws_ssm_parameter" "secrets" {
  for_each = local.secret_map
  name     = "/llm-platform/${var.env_name}/${each.key}"
  type     = "SecureString"
  value    = each.value
}

# ── IAM for the instance ────────────────────────────────────────────────────

data "aws_iam_policy_document" "ec2_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "instance" {
  name               = "llm-platform-instance"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.instance.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy_attachment" "ecr" {
  role       = aws_iam_role.instance.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

resource "aws_iam_role_policy" "parameter_store" {
  name = "llm-params"
  role = aws_iam_role.instance.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["ssm:GetParameter", "ssm:GetParameters", "ssm:GetParametersByPath"]
        Resource = "arn:aws:ssm:${var.region}:*:parameter/llm-platform/${var.env_name}/*"
      },
      {
        Effect   = "Allow"
        Action   = ["ssm:PutParameter"]
        Resource = "arn:aws:ssm:${var.region}:*:parameter/llm-platform/${var.env_name}/apps/*"
      }
    ]
  })
}

resource "aws_iam_instance_profile" "instance" {
  name = "llm-platform-instance"
  role = aws_iam_role.instance.name
}

# ── ECR repo for the orchestration image (gateway + vllm pull from public) ──

resource "aws_ecr_repository" "orchestration" {
  name                 = "llm-platform/orchestration"
  image_tag_mutability = "MUTABLE"
  force_delete         = true
}

# ── AMI: AWS Deep Learning Base GPU AMI (Ubuntu 22.04) ──────────────────────

data "aws_ami" "dlami" {
  most_recent = true
  owners      = ["amazon"]
  filter {
    name   = "name"
    values = ["Deep Learning Base OSS Nvidia Driver GPU AMI (Ubuntu 22.04)*"]
  }
  filter {
    name   = "architecture"
    values = ["x86_64"]
  }
}

# ── EC2 instance ────────────────────────────────────────────────────────────

resource "aws_instance" "this" {
  ami                    = data.aws_ami.dlami.id
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.public[0].id
  vpc_security_group_ids = [aws_security_group.instance.id]
  iam_instance_profile   = aws_iam_instance_profile.instance.name

  root_block_device {
    volume_type           = "gp3"
    volume_size           = 200
    delete_on_termination = true
    tags                  = { Name = "llm-platform-root" }
  }

  user_data = templatefile("${path.module}/user-data.sh.tpl", {
    region              = var.region
    env_name            = var.env_name
    account_id          = data.aws_caller_identity.current.account_id
    orchestration_image = "${aws_ecr_repository.orchestration.repository_url}:${var.orchestration_tag}"
    public_dns_name     = "llm.kleem.io"
    apps                = jsonencode(var.apps)
    vllm_model          = var.vllm_model
  })

  user_data_replace_on_change = true

  tags = { Name = "llm-platform" }
}

# ── ALB + HTTPS listener + Route53 ──────────────────────────────────────────

resource "aws_lb" "this" {
  name               = "llm-platform"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = aws_subnet.public[*].id
  idle_timeout       = 120 # long-running SSE streams
}

resource "aws_lb_target_group" "gateway" {
  name        = "llm-gateway"
  port        = 4000
  protocol    = "HTTP"
  vpc_id      = aws_vpc.this.id
  target_type = "instance"

  health_check {
    path                = "/health/liveliness"
    matcher             = "200"
    interval            = 30
    timeout             = 10
    healthy_threshold   = 2
    unhealthy_threshold = 5
  }

  # SSE-friendly: don't reset connections aggressively
  deregistration_delay = 30
}

resource "aws_lb_target_group_attachment" "gateway" {
  target_group_arn = aws_lb_target_group.gateway.arn
  target_id        = aws_instance.this.id
  port             = 4000
}

resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.this.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = data.aws_acm_certificate.kleem.arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.gateway.arn
  }
}

resource "aws_lb_listener" "http_redirect" {
  load_balancer_arn = aws_lb.this.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "redirect"
    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }
}

resource "aws_route53_record" "llm" {
  zone_id = data.aws_route53_zone.kleem.zone_id
  name    = "llm.kleem.io"
  type    = "A"
  alias {
    name                   = aws_lb.this.dns_name
    zone_id                = aws_lb.this.zone_id
    evaluate_target_health = true
  }
}

# ── cost-aware scheduling: EventBridge Scheduler stop/start ─────────────────

data "aws_iam_policy_document" "scheduler_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["scheduler.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "scheduler" {
  count              = var.enable_schedule ? 1 : 0
  name               = "llm-platform-scheduler"
  assume_role_policy = data.aws_iam_policy_document.scheduler_assume.json
}

resource "aws_iam_role_policy" "scheduler_ec2" {
  count = var.enable_schedule ? 1 : 0
  name  = "ec2-start-stop"
  role  = aws_iam_role.scheduler[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["ec2:StartInstances", "ec2:StopInstances"]
      Resource = aws_instance.this.arn
    }]
  })
}

resource "aws_scheduler_schedule" "stop_nightly" {
  count                        = var.enable_schedule ? 1 : 0
  name                         = "llm-platform-stop-nightly"
  schedule_expression          = "cron(0 22 ? * MON-FRI *)"
  schedule_expression_timezone = "Asia/Kolkata"
  flexible_time_window { mode = "OFF" }

  target {
    arn      = "arn:aws:scheduler:::aws-sdk:ec2:stopInstances"
    role_arn = aws_iam_role.scheduler[0].arn
    input    = jsonencode({ InstanceIds = [aws_instance.this.id] })
  }
}

resource "aws_scheduler_schedule" "start_morning" {
  count                        = var.enable_schedule ? 1 : 0
  name                         = "llm-platform-start-morning"
  schedule_expression          = "cron(0 8 ? * MON-FRI *)"
  schedule_expression_timezone = "Asia/Kolkata"
  flexible_time_window { mode = "OFF" }

  target {
    arn      = "arn:aws:scheduler:::aws-sdk:ec2:startInstances"
    role_arn = aws_iam_role.scheduler[0].arn
    input    = jsonencode({ InstanceIds = [aws_instance.this.id] })
  }
}
