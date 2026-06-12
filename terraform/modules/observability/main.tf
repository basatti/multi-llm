# Observability scaffold. All platform telemetry hangs off the gateway because
# every request crosses it (architecture.md §9). Dashboard widgets get real
# metrics once Phase 0 traffic flows; the text stub records what must exist.

resource "aws_sns_topic" "alarms" {
  name = "llm-platform-alarms-${var.env}"
}

resource "aws_cloudwatch_dashboard" "platform" {
  dashboard_name = "llm-platform-${var.env}"

  dashboard_body = jsonencode({
    widgets = [{
      type   = "text"
      x      = 0
      y      = 0
      width  = 24
      height = 6
      properties = {
        markdown = join("\n", [
          "# LLM Platform — ${var.env}",
          "Required dashboards (architecture.md §9), populated during Phase 0:",
          "1. Cost per product per day, local vs frontier (the migration scoreboard)",
          "2. TTFT p50/p95/p99 per logical model (Kleem SLO view)",
          "3. GPU utilization vs queue depth per deployment",
          "4. Fallback rate per logical name (earliest capacity/health warning)",
          "5. Error and retry rates per backend",
        ])
      }
    }]
  })
}
