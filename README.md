# 1TechHub LLM Platform (`llm-repo`)

Shared LLM serving platform for Kleem, PMS, and Qams. Four strictly ordered
layers — full design in [docs/architecture.md](docs/architecture.md):

```
products (Kleem · PMS · Qams)
   │ stateful/agentic            │ stateless one-shots
   ▼                             │
orchestration (sessions · memory · RAG · agent loops)
   ▼                             ▼
gateway (LiteLLM: virtual keys · routing · budgets · fallback · telemetry)
   ▼                             ▼
inference (vLLM on AWS GPU)   frontier APIs (Anthropic/OpenAI/Bedrock)
```

Core invariant: **inference is stateless and isolated** — messages in, tokens
out. Sessions, memory, and tools live only in orchestration. Every model call
from every product crosses the gateway.

## Repo layout

| Path | What it is |
|---|---|
| `docs/` | Architecture doc, ADRs, runbooks |
| `gateway/` | LiteLLM config (logical model routes), pinned Dockerfile, key bootstrap |
| `models/` | Model manifest: the source of truth for what inference serves |
| `orchestration/` | FastAPI service: sessions, SSE streaming, app registry (§6.4), Langfuse + LiteLLM clients |
| `mock-openai/` | OpenAI-compatible mock backend for the local harness |
| `compose/` | Local-harness assets (Postgres init script, etc.) |
| `scripts/` | `validate_routes.py` — manifest ↔ gateway route consistency (CI-enforced) |
| `terraform/` | AWS IaC: network, gateway (Fargate), Redis, secrets, inference placeholder |

**The atomic-PR rule:** adding or moving a model = one PR changing
`models/manifest.yaml` + `gateway/config/config.yaml` together. CI rejects
routes to non-manifested models. Apps call the gateway by model name
(`llama3.1`, `gemma4`, `qwen2.5-coder` today); per-key scoping in LiteLLM
controls what each app may invoke.

## Quickstart (local harness — no AWS, no GPUs)

```bash
cp .env.example .env
make up    # litellm + postgres + redis + langfuse stack + orchestration + mock backend

# chat through the gateway (master key is fine locally)
curl -s http://localhost:4000/v1/chat/completions \
  -H "Authorization: Bearer sk-local-dev-only" -H "Content-Type: application/json" \
  -d '{"model": "llama3.1", "messages": [{"role": "user", "content": "hi"}]}'

# stateful session through orchestration (streams SSE)
curl -s -X POST http://localhost:8000/v1/sessions \
  -H "Content-Type: application/json" -d '{"product": "kleem", "tenant_id": "t1"}'
curl -N -X POST http://localhost:8000/v1/sessions/<session_id>/messages \
  -H "Content-Type: application/json" -d '{"content": "hello"}'

# register an app — fans out to LiteLLM (virtual key) + Langfuse (prompt
# namespace) + orchestration's app_profiles table (§6.4)
curl -s -X POST http://localhost:8000/v1/apps \
  -H "Content-Type: application/json" \
  -d '{"app_id":"kleem-demo","owner":"voice-team","cost_center":"kleem-prod",
       "models":["chat-default"],"agent_config":{"logical_model":"chat-default"}}'

# invoke under the issued virtual key — template fetched from Langfuse, compiled,
# call streamed from the gateway under the app's key
curl -N -X POST http://localhost:8000/v1/apps/kleem-demo/invoke \
  -H "Authorization: Bearer <virtual_key_from_register>" \
  -H "Content-Type: application/json" \
  -d '{"template_id":"system","variables":{"app_name":"Kleem"},"input":"hi"}'

# test the fallback chain: fail one model, watch a peer model serve
MOCK_FAIL_MODELS=llama3.1:8b make up

# Route the gateway at a REAL local LLM on the host (Ollama by default;
# set LOCAL_LLM_BASE_URL=http://host.docker.internal:1234/v1 for LM Studio).
# Model id is fixed in gateway/config/config.local-llm.yaml — edit + recompose
# to switch. The mock backend stays running as the frontier-fallback target.
make up-local-llm

# Langfuse UI: http://localhost:3000 (admin@onetechhub.local / LANGFUSE_INIT_USER_PASSWORD)
```

Other targets: `make test` (orchestration tests), `make validate`
(manifest↔route check), `make tf-validate`, `make down`.

## Deployment

Terraform under `terraform/envs/{dev,staging,prod}` (region `ap-south-1`).
Phase 0 deploys the gateway tier only; `terraform/modules/inference` is a
deliberate placeholder pending the Phase 1 go/no-go and ADR 0001. Secrets are
Secrets Manager shells — values are set out-of-band, never in state or config.

Rollout phases, budgets, and governance: [docs/architecture.md](docs/architecture.md) §11.
