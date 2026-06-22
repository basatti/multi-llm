# Gateway (LiteLLM proxy)

The single front door for all model access (architecture.md §5). Stateless and
conversation-blind: keys, budgets, routes, backends — nothing else.

- `config/config.yaml` — canonical routing (logical names + frontier fallbacks).
- `config/config.cloud.yaml` — self-hosted / cloud routing: three Ollama-served models.
- `config/config.local.yaml` — compose harness; all backends → mock-openai.
- `config/config.local-llm.yaml` — compose harness routed at a real local LLM on the host.
- `Dockerfile` — pinned LiteLLM image (see supply-chain policy in the file).

## Virtual keys

Applications and orchestration never hold provider credentials. Each service
gets a gateway-issued virtual key, scoped and budgeted. Real credentials
(Anthropic, OpenAI, internal inference endpoints) exist only in the gateway's
environment (your secret manager in deployment; `.env` locally).

### Issue a key (per application/service)

```bash
curl -s http://localhost:4000/key/generate \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "key_alias": "my-app",
    "models": ["llama3.1", "gemma4"],
    "max_budget": 500,
    "budget_duration": "30d",
    "rpm_limit": 600,
    "metadata": {"app_id": "my-app"}
  }'
```

Budgets and rate limits are blast-radius containment (§5.1): a runaway loop in
one application cannot exhaust capacity or spend for the others.

### Use a key

```bash
curl -s http://localhost:4000/v1/chat/completions \
  -H "Authorization: Bearer sk-<virtual-key>" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "llama3.1",
    "messages": [{"role": "user", "content": "hello"}],
    "metadata": {"tenant_id": "acme-co"}
  }'
```

### Rotate / revoke

```bash
# revoke
curl -s http://localhost:4000/key/delete \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
  -d '{"keys": ["sk-<virtual-key>"]}'
# rotate = generate new key with same alias/scopes, deploy, then revoke old
```

## Tenant attribution (mandatory)

Per-application attribution comes from the virtual key. Per-tenant attribution
comes from the request: **multi-tenant applications MUST send
`metadata.tenant_id` on every request** (architecture.md §5.1/§9). It lands in
the gateway request log alongside key, logical model, resolved backend, token
counts, TTFT, and computed cost — the single source of truth for
"what did application X / tenant Y cost, local vs frontier".

## Routing modes

The gateway supports two routing styles, picked by which config file you load:

**Direct model names** (`config.cloud.yaml` — what the self-hosted runbook uses):
each route's `model_name` is the literal model an application asks for
(`llama3.1`, `gemma4`, `qwen2.5-coder`). Simple, debuggable. Per-application
control is through the key's `models: [...]` scope in the LiteLLM admin UI.

**Logical names with fallback chains** (`config.yaml` — the architectural
target): applications request a *role* like `chat-default` or `summarize-cheap`,
and the gateway resolves it to a primary backend plus an ordered fallback
list. Re-pointing a logical name is a config change here — invisible to
applications. Routes with `model_info.source: local` must reference
`models/manifest.yaml` ids (`model_info.manifest_id`); CI enforces it.
