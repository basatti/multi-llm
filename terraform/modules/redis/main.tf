# ElastiCache Redis: shared rate-limit counters and optional response cache.
# The only shared state in the gateway tier — proxy processes stay stateless (§5.2).

resource "aws_security_group" "redis" {
  name        = "llm-platform-redis-${var.env}"
  description = "Redis: platform services only"
  vpc_id      = var.vpc_id

  ingress {
    from_port       = 6379
    to_port         = 6379
    protocol        = "tcp"
    security_groups = var.allowed_sg_ids
  }
}

resource "aws_elasticache_subnet_group" "this" {
  name       = "llm-platform-${var.env}"
  subnet_ids = var.subnet_ids
}

resource "aws_elasticache_replication_group" "this" {
  replication_group_id       = "llm-platform-${var.env}"
  description                = "Gateway rate-limit counters / cache + orchestration hot sessions"
  engine                     = "redis"
  node_type                  = var.node_type
  num_cache_clusters         = var.num_nodes
  port                       = 6379
  automatic_failover_enabled = var.num_nodes > 1
  subnet_group_name          = aws_elasticache_subnet_group.this.name
  security_group_ids         = [aws_security_group.redis.id]
}
