variable "region" {
  type    = string
  default = "ap-south-1"
}

variable "env" {
  type    = string
  default = "prod"
}

variable "vpc_cidr" {
  type    = string
  default = "10.42.0.0/16"
}

variable "gateway_image" {
  description = "ECR URI of the image built from gateway/Dockerfile"
  type        = string
}

variable "gateway_desired_count" {
  type    = number
  default = 2
}

variable "log_retention_days" {
  # Gateway request logs retained per compliance / PDPL obligations (§10)
  type    = number
  default = 365
}
