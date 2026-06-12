variable "region" {
  type    = string
  default = "ap-south-1"
}

variable "env" {
  type    = string
  default = "staging"
}

variable "vpc_cidr" {
  type    = string
  default = "10.41.0.0/16"
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
  type    = number
  default = 90
}
