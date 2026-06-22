terraform {
  required_version = ">= 1.7"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.60"
    }
  }

  # Enable once the state bucket exists (Phase 0 bootstrap):
  # backend "s3" {
  #   bucket         = "your-terraform-state-bucket"
  #   key            = "llm-platform/dev.tfstate"
  #   region         = "ap-south-1"
  #   dynamodb_table = "terraform-locks"
  #   encrypt        = true
  # }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project     = "llm-platform"
      Environment = var.env
      ManagedBy   = "terraform"
    }
  }
}

module "network" {
  source   = "../../modules/network"
  env      = var.env
  vpc_cidr = var.vpc_cidr
}

module "secrets" {
  source = "../../modules/secrets"
  env    = var.env
  secret_names = {
    "litellm-master-key"   = "Gateway admin key (issues/revokes virtual keys)"
    "anthropic-api-key"    = "Frontier provider credential - gateway only"
    "gateway-database-url" = "LiteLLM virtual-key store connection string (composed from RDS master secret out-of-band)"
  }
}

module "redis" {
  source         = "../../modules/redis"
  env            = var.env
  vpc_id         = module.network.vpc_id
  subnet_ids     = module.network.platform_subnet_ids
  allowed_sg_ids = [module.network.gateway_sg_id]
}

module "inference" {
  source         = "../../modules/inference"
  vpc_id         = module.network.vpc_id
  gpu_subnet_ids = module.network.gpu_subnet_ids
  gpu_sg_id      = module.network.gpu_sg_id
  manifest_path  = "${path.module}/../../../models/manifest.yaml"
}

module "gateway" {
  source        = "../../modules/gateway"
  env           = var.env
  vpc_id        = module.network.vpc_id
  subnet_ids    = module.network.platform_subnet_ids
  alb_sg_id     = module.network.alb_sg_id
  service_sg_id = module.network.gateway_sg_id
  image         = var.gateway_image
  desired_count = var.gateway_desired_count
  redis_host    = module.redis.endpoint
  redis_port    = module.redis.port
  vllm_base_url = module.inference.inference_endpoint_url
  secret_arns = {
    LITELLM_MASTER_KEY = module.secrets.arns["litellm-master-key"]
    ANTHROPIC_API_KEY  = module.secrets.arns["anthropic-api-key"]
    DATABASE_URL       = module.secrets.arns["gateway-database-url"]
  }
  log_retention_days = var.log_retention_days
}

module "observability" {
  source = "../../modules/observability"
  env    = var.env
}

output "gateway_endpoint" {
  value = module.gateway.alb_dns_name
}
