variable "region" {
  type    = string
  default = "ap-south-1"
}

variable "env_name" {
  description = "Used in SSM parameter paths and tags. Distinct from architecture-doc dev/staging/prod (which target a different topology)."
  type        = string
  default     = "prod"
}

variable "instance_type" {
  description = "Cost-minded GPU starter. g4dn.xlarge: 1x T4 (16 GB), $0.526/hr in ap-south-1 — runs Qwen2.5-7B-AWQ comfortably."
  type        = string
  default     = "g4dn.xlarge"
}

variable "orchestration_tag" {
  description = "ECR tag to deploy. Bump each time you push a new orchestration image."
  type        = string
  default     = "latest"
}

variable "enable_schedule" {
  description = "Auto-stop nightly (22:00 IST) and weekends; auto-start weekday mornings (08:00 IST). Set false for 24/7 availability."
  type        = bool
  default     = true
}

variable "apps" {
  description = "Apps registered on first boot. Each gets a virtual key in LiteLLM scoped to one model, a Langfuse prompt namespace, and an app_profiles row. Keys are written to SSM at /llm-platform/<env>/apps/{id}/api_key. Re-scope freely via the LiteLLM admin UI (https://litellm.kleem.io/ui/) — these defaults are starting points only."
  type = list(object({
    id           = string
    owner        = string
    cost_center  = string
    models       = list(string)
    primary_model = string
  }))
  default = [
    { id = "kleem", owner = "voice-team", cost_center = "kleem-prod", models = ["llama3.1"], primary_model = "llama3.1" },
    { id = "pms", owner = "platform-team", cost_center = "pms-prod", models = ["gemma4"], primary_model = "gemma4" },
    { id = "qams", owner = "accreditation-team", cost_center = "qams-prod", models = ["qwen2.5-coder"], primary_model = "qwen2.5-coder" },
  ]
}
