output "vpc_id" {
  value = aws_vpc.this.id
}

output "vpc_cidr" {
  value = aws_vpc.this.cidr_block
}

output "app_subnet_ids" {
  value = aws_subnet.app[*].id
}

output "platform_subnet_ids" {
  value = aws_subnet.platform[*].id
}

output "gpu_subnet_ids" {
  value = aws_subnet.gpu[*].id
}

output "alb_sg_id" {
  value = aws_security_group.alb.id
}

output "gateway_sg_id" {
  value = aws_security_group.gateway.id
}

output "gpu_sg_id" {
  value = aws_security_group.gpu.id
}
