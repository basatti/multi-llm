output "gateway_url" {
  description = "Public TLS gateway. Hit /v1/chat/completions with one of the issued virtual keys."
  value       = "https://llm.kleem.io"
}

output "instance_id" {
  value = aws_instance.this.id
}

output "alb_dns_name" {
  description = "Useful only for diagnostics; use the Route53 record."
  value       = aws_lb.this.dns_name
}

output "ssh_command" {
  description = "Reach the box via SSM Session Manager (no SSH key issued)."
  value       = "aws ssm start-session --region ${var.region} --target ${aws_instance.this.id}"
}

output "api_keys_command" {
  description = "Run this after the instance finishes bootstrap (~5–10 min on first boot) to fetch the issued virtual keys."
  value       = "aws ssm get-parameters-by-path --region ${var.region} --path /llm-platform/${var.env_name}/apps --recursive --with-decryption --query 'Parameters[].[Name,Value]' --output table"
}

output "ecr_repo" {
  value = aws_ecr_repository.orchestration.repository_url
}

output "schedule_status" {
  value = var.enable_schedule ? "Auto-stop 22:00 IST weekdays + all weekend; auto-start 08:00 IST weekdays. Disable with -var enable_schedule=false." : "Always-on (enable_schedule=false)."
}
