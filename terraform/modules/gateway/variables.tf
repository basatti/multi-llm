variable "env" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "subnet_ids" {
  description = "Platform-tier private subnets"
  type        = list(string)
}

variable "alb_sg_id" {
  type = string
}

variable "service_sg_id" {
  type = string
}

variable "image" {
  description = "Gateway image (built from gateway/Dockerfile, pinned LiteLLM)"
  type        = string
}

variable "desired_count" {
  description = "Minimum two replicas: the gateway must not be a single point of failure (section 5.2)"
  type        = number
  default     = 2
}

variable "cpu" {
  type    = string
  default = "512"
}

variable "memory" {
  type    = string
  default = "1024"
}

variable "redis_host" {
  type = string
}

variable "redis_port" {
  type    = number
  default = 6379
}

variable "vllm_base_url" {
  description = "Inference layer endpoint; null until Phase 1 stands it up"
  type        = string
  default     = null
}

variable "secret_arns" {
  description = "Container env name -> Secrets Manager ARN (LITELLM_MASTER_KEY, ANTHROPIC_API_KEY, DATABASE_URL, ...)"
  type        = map(string)
}

variable "db_instance_class" {
  type    = string
  default = "db.t4g.micro"
}

variable "db_skip_final_snapshot" {
  type    = bool
  default = true
}

variable "log_retention_days" {
  type    = number
  default = 30
}
