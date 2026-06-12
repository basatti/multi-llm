# Secrets Manager SHELLS only. Values are never set from Terraform — they
# would land in state. Populate out-of-band after apply:
#
#   aws secretsmanager put-secret-value \
#     --secret-id llm-platform/<env>/<name> --secret-string '<value>'
#
# Real provider credentials exist only here; products and orchestration hold
# revocable virtual keys (architecture.md §10).

resource "aws_secretsmanager_secret" "this" {
  for_each    = var.secret_names
  name        = "llm-platform/${var.env}/${each.key}"
  description = each.value
}
