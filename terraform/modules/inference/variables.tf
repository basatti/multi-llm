variable "vpc_id" {
  type = string
}

variable "gpu_subnet_ids" {
  type = list(string)
}

variable "gpu_sg_id" {
  description = "Pre-wired SG: ingress only from the gateway (network module)"
  type        = string
}

variable "manifest_path" {
  description = "Path to models/manifest.yaml — the source of truth for what this module must serve"
  type        = string
}
