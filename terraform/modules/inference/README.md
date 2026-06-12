# Inference module (placeholder)

Layer 1 — the "LLM repo" proper: vLLM nodes serving the models declared in
`models/manifest.yaml`. **Deliberately unimplemented** until two decisions land:

1. **Compute platform** — EKS + Karpenter vs ECS + ASG. Tracked in
   `docs/decisions/0001-gpu-compute-platform.md`. Phase 1 work.
2. **Phase 1 go/no-go** — break-even calc from Phase 0 gateway telemetry
   (docs/architecture.md §11). No GPU spend before the math works.

## Contract any implementation must satisfy

- Exposes an **OpenAI-compatible** `/v1/chat/completions` + `/v1/completions`
  endpoint on port 8000, reachable **only** from the gateway SG (`gpu_sg_id`
  is pre-wired for this in the network module).
- **Stateless**: messages in, tokens out. No DB access, no session lookup, no
  tool execution (architecture.md §4.1).
- Serves exactly what `models/manifest.yaml` declares: base models + LoRA
  adapters via vLLM multi-LoRA, quantization per manifest.
- Autoscales on **queue depth and TTFT**, not utilization alone; warm minimum
  of one replica per actively routed model; scale-to-zero only where the
  manifest allows it (§4.3).
- Weights pulled from in-region S3 (or warm EBS/FSx cache) on boot.
- Emits the endpoint as `inference_endpoint_url`, which the env wiring feeds
  to the gateway as `VLLM_BASE_URL`.
