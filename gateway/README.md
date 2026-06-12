# Gateway (LiteLLM proxy)

The single front door for all model access (architecture.md §5). Stateless and
conversation-blind: keys, budgets, routes, backends — nothing else.

- `config/config.yaml` — canonical routing (AWS). Logical names → physical backends.
- `config/config.local.yaml` — compose harness; all backends → mock-openai.
- `Dockerfile` — pinned LiteLLM image (see supply-chain policy in the file).

## Virtual keys

Products and orchestration never hold provider credentials. Each service gets a
gateway-issued virtual key, scoped and budgeted. Real credentials (Anthropic,
vLLM endpoints) exist only in the gateway's environment (AWS Secrets Manager in
deployment; `.env` locally).

### Issue a key (per product/service)

```bash
curl -s http://localhost:4000/key/generate \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "key_alias": "qams-prod",
    "models": ["qams-rag", "summarize-cheap"],
    "max_budget": 500,
    "budget_duration": "30d",
    "rpm_limit": 600,
    "metadata": {"product": "qams"}
  }'
```

Budgets and rate limits are blast-radius containment (§5.1): a runaway loop in
one product cannot exhaust capacity or spend for the others.

### Use a key

```bash
curl -s http://localhost:4000/v1/chat/completions \
  -H "Authorization: Bearer sk-<virtual-key>" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "chat-default",
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

Per-product attribution comes from the virtual key. Per-tenant attribution
comes from the request: **tenant-scoped products MUST send
`metadata.tenant_id` on every request** (architecture.md §5.1/§9). It lands in
the gateway request log alongside key, logical model, resolved backend, token
counts, TTFT, and computed cost — the single source of truth for
"what did product X / tenant Y cost, local vs frontier".

## Logical model tiers

| Logical name | Tier | Primary | Fallback |
|---|---|---|---|
| `kleem-realtime` | realtime voice, TTFT ≤ 400 ms | local small quantized | fast frontier |
| `chat-default` | standard product features | local base | frontier |
| `qams-rag` | quality / accuracy-first | frontier | — (local candidate gated on Phase 3 benchmarks) |
| `summarize-cheap` | batch/async | local (LoRA) | chat-default-frontier |

Re-pointing a logical name is a config change here — invisible to products.
Routes with `model_info.source: local` must reference `models/manifest.yaml`
ids (`model_info.manifest_id`); CI enforces it.
