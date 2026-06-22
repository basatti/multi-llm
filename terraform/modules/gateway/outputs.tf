output "alb_dns_name" {
  description = "Internal gateway endpoint; map your internal DNS record (e.g. llm-gateway.internal) to this"
  value       = aws_lb.this.dns_name
}

output "cluster_arn" {
  value = aws_ecs_cluster.this.arn
}

output "db_endpoint" {
  value = aws_db_instance.keystore.endpoint
}
