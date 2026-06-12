# Gateway: pinned LiteLLM on ECS Fargate, >=2 replicas behind an internal ALB
# (architecture.md §5). Stateless: Redis holds shared counters, RDS holds the
# virtual-key store. Provider credentials arrive only via Secrets Manager.

data "aws_region" "current" {}

resource "aws_ecs_cluster" "this" {
  name = "llm-platform-${var.env}"
}

resource "aws_cloudwatch_log_group" "gateway" {
  name              = "/llm-platform/${var.env}/gateway"
  retention_in_days = var.log_retention_days
}

# ── IAM ──────────────────────────────────────────────────────────────────────

data "aws_iam_policy_document" "ecs_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "execution" {
  name               = "llm-gateway-execution-${var.env}"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume.json
}

resource "aws_iam_role_policy_attachment" "execution" {
  role       = aws_iam_role.execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_role_policy" "read_secrets" {
  name = "read-gateway-secrets"
  role = aws_iam_role.execution.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["secretsmanager:GetSecretValue"]
      Resource = values(var.secret_arns)
    }]
  })
}

resource "aws_iam_role" "task" {
  name               = "llm-gateway-task-${var.env}"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume.json
}

# ── Task + service ───────────────────────────────────────────────────────────

locals {
  env_vars = {
    REDIS_HOST    = var.redis_host
    REDIS_PORT    = tostring(var.redis_port)
    VLLM_BASE_URL = var.vllm_base_url
  }
  container_env     = [for k, v in local.env_vars : { name = k, value = v } if v != null]
  container_secrets = [for k, v in var.secret_arns : { name = k, valueFrom = v }]
}

resource "aws_ecs_task_definition" "gateway" {
  family                   = "llm-gateway-${var.env}"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.cpu
  memory                   = var.memory
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.task.arn

  container_definitions = jsonencode([{
    name      = "litellm"
    image     = var.image
    essential = true
    portMappings = [{
      containerPort = 4000
      protocol      = "tcp"
    }]
    environment = local.container_env
    secrets     = local.container_secrets
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        awslogs-group         = aws_cloudwatch_log_group.gateway.name
        awslogs-region        = data.aws_region.current.name
        awslogs-stream-prefix = "gateway"
      }
    }
  }])
}

resource "aws_lb" "this" {
  name               = "llm-gateway-${var.env}"
  internal           = true
  load_balancer_type = "application"
  security_groups    = [var.alb_sg_id]
  subnets            = var.subnet_ids
}

resource "aws_lb_target_group" "gateway" {
  name        = "llm-gateway-${var.env}"
  port        = 4000
  protocol    = "HTTP"
  vpc_id      = var.vpc_id
  target_type = "ip"

  health_check {
    path    = "/health/liveliness"
    matcher = "200"
  }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.this.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.gateway.arn
  }
}

resource "aws_ecs_service" "gateway" {
  name            = "llm-gateway"
  cluster         = aws_ecs_cluster.this.id
  task_definition = aws_ecs_task_definition.gateway.arn
  desired_count   = var.desired_count
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = var.subnet_ids
    security_groups  = [var.service_sg_id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.gateway.arn
    container_name   = "litellm"
    container_port   = 4000
  }

  depends_on = [aws_lb_listener.http]
}

# ── Virtual-key store (RDS Postgres) ─────────────────────────────────────────
# manage_master_user_password keeps the DB password out of Terraform state.
# Ops composes the full DATABASE_URL into the gateway-database-url secret
# out-of-band (see terraform/modules/secrets).

resource "aws_security_group" "db" {
  name        = "llm-gateway-db-${var.env}"
  description = "LiteLLM key store: gateway tasks only"
  vpc_id      = var.vpc_id

  ingress {
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [var.service_sg_id]
  }
}

resource "aws_db_subnet_group" "this" {
  name       = "llm-gateway-${var.env}"
  subnet_ids = var.subnet_ids
}

resource "aws_db_instance" "keystore" {
  identifier                  = "llm-gateway-keystore-${var.env}"
  engine                      = "postgres"
  engine_version              = "16"
  instance_class              = var.db_instance_class
  allocated_storage           = 20
  db_name                     = "litellm"
  username                    = "litellm"
  manage_master_user_password = true
  db_subnet_group_name        = aws_db_subnet_group.this.name
  vpc_security_group_ids      = [aws_security_group.db.id]
  skip_final_snapshot         = var.db_skip_final_snapshot
}
