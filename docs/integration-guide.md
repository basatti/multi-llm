# Client integration guide

How an application connects to the LLM platform.

The gateway is OpenAI wire-compatible. Any client that targets the OpenAI API
works by setting two things: the base URL, and the API key.

Throughout this guide, **`https://<gateway-host>`** is the URL of your
gateway deployment — `https://localhost:4000` for the local harness, or the
hostname of your production endpoint (e.g. `https://llm.example.com`).

---

## Endpoint

```
Base URL:           https://<gateway-host>/v1
Chat completions:   POST https://<gateway-host>/v1/chat/completions
Models list:        GET  https://<gateway-host>/v1/models
Health:             GET  https://<gateway-host>/health/liveliness
```

The gateway terminates TLS (when fronted by a reverse proxy or ALB),
authenticates the virtual key, routes to the requested model, streams
tokens back unbuffered, and logs cost + latency telemetry.

---

## Models

The default deployment hosts three open-weight models on a single GPU via
Ollama hot-swap: only one is GPU-resident at any moment; the active one
swaps when a request targets a different model. First request after a swap
is slower (~10–20 s warm-up); subsequent calls are fast.

| Model name (use in the `model` field) | Sweet spot |
|---|---|
| `llama3.1` | General chat, conversational features, low-latency replies (Llama 3.1 8B) |
| `gemma4` | Drafting, summarization, longer-form writing (Google Gemma 4 latest) |
| `qwen2.5-coder` | Code generation, structured extraction, technical text (Qwen 2.5 Coder 7B) |

Re-scoping any key to a different (or additional) model is a config change in
the LiteLLM admin UI (`https://<gateway-host>/ui/`) — no application redeploy.

To add a model: update `models/manifest.yaml` and
`gateway/config/config.cloud.yaml` together in one PR (the atomic-PR rule).
For Ollama-served models, also `docker compose exec ollama ollama pull <tag>`
on the host.

---

## Authentication

Each application has its own virtual key, bound to one (or more) models.
**Never commit a key to the repo.** Pull it from your secret manager at
application startup — AWS SSM, HashiCorp Vault, Doppler, a sealed K8s
secret, or whatever you already use.

Example with AWS SSM:

```bash
aws ssm get-parameter --region <your-region> \
  --name /llm-platform/<env>/apps/<app-id>/api_key \
  --with-decryption --query Parameter.Value --output text
```

To issue a new key (operator action — needs the LiteLLM master key):

```bash
curl -sS -X POST https://<gateway-host>/key/generate \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "key_alias": "my-app",
    "models": ["llama3.1"],
    "max_budget": 50,
    "budget_duration": "30d",
    "metadata": {"tenant_id": "my-app"}
  }'
```

A request to a model the key isn't scoped to returns `401`.

---

## Tenant attribution (mandatory for multi-tenant applications)

Multi-tenant applications **must** send `metadata.tenant_id` on every
request. It lands in the gateway log alongside the virtual key, model,
cost, and latency — that's how spend is attributed per tenant.

```json
{
  "model": "llama3.1",
  "messages": [{"role": "user", "content": "…"}],
  "metadata": {"tenant_id": "acme-co"}
}
```

`metadata.feature` is also useful — it lets you separate spend by call site
(e.g. `summarisation` vs `chat` vs `drafting`) within the same application.

---

## Snippets

### Node / TypeScript

```ts
import OpenAI from "openai";

const llm = new OpenAI({
  baseURL: "https://<gateway-host>/v1",
  apiKey: process.env.LLM_PLATFORM_KEY,        // pulled from your secret store at boot
});

// Streaming chat turn
const turn = await llm.chat.completions.create({
  model: "llama3.1",
  messages,
  stream: true,
  // @ts-expect-error - metadata passthrough
  metadata: { tenant_id: session.tenantId, feature: "chat" },
});

for await (const chunk of turn) {
  const piece = chunk.choices[0]?.delta?.content ?? "";
  // pipe to TTS / UI / etc.
}

// One-shot non-stream
const summary = await llm.chat.completions.create({
  model: "gemma4",
  messages: [
    { role: "system", content: "Summarize the conversation in 3 bullets." },
    { role: "user", content: transcript },
  ],
  // @ts-expect-error
  metadata: { tenant_id: call.tenantId, feature: "summary" },
});
```

### Python

```python
import os
from openai import OpenAI

llm = OpenAI(
    base_url="https://<gateway-host>/v1",
    api_key=os.environ["LLM_PLATFORM_KEY"],
)

resp = llm.chat.completions.create(
    model="qwen2.5-coder",
    messages=[
        {"role": "system", "content": rubric_prompt},
        {"role": "user", "content": retrieved_evidence_block},
    ],
    extra_body={"metadata": {"tenant_id": tenant_id, "feature": "extraction"}},
)
result = resp.choices[0].message.content
```

---

## Streaming (SSE)

Set `stream: true` — token-level delivery is preserved end-to-end (gateway,
any TLS-terminating proxy, and the inference backend all flush per chunk).
Client disconnects propagate as upstream cancellation, freeing the GPU slot
immediately.

```bash
curl -N https://<gateway-host>/v1/chat/completions \
  -H "Authorization: Bearer $LLM_PLATFORM_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "llama3.1",
    "messages": [{"role": "user", "content": "hi"}],
    "stream": true,
    "metadata": {"tenant_id": "demo"}
  }'
```

---

## Errors

| Code | Meaning |
|---|---|
| `401` | Missing/invalid `Authorization: Bearer …`, OR the key isn't scoped to the requested model |
| `429` | Per-key rate limit or budget cap hit. Check the key's budget in the LiteLLM admin UI |
| `400` | Malformed request — usually `messages` shape or unknown model name |
| `500` / `502` | Backend failure — gateway falls back automatically (each model falls back to a peer model); if you see persistent 502, something deeper is wrong |
| `504` | Backend timed out at the proxy/load-balancer in front of the gateway. Most common cause: the inference host is stopped or unreachable. Check that the GPU host is up and that the gateway can resolve `ollama:11434`. |

---

## First-call latency

On a cold model (first request after a swap or a fresh boot):

| Scenario | TTFT |
|---|---|
| Host just started, no model loaded | ~30–60 s (model loads into VRAM from disk) |
| Host warm, different model active | ~10–20 s (swap) |
| Host warm, requested model already active | ~200–800 ms |

If you're benchmarking or building anything latency-sensitive, send a warm-up
request 5–10 s before the real one — that puts the model in VRAM and the
real call hits the fast path.

---

## Operational notes

- **Cost-aware scheduling (cloud deployments):** some operators run an
  EventBridge/cron rule that stops the GPU host outside business hours.
  Clients that hit the gateway during off-hours will see `504` until the
  host starts. Plan demos accordingly.
- **Logs and traces:** every request is logged at the gateway and traced in
  Langfuse (`http://<gateway-host>:3000` in the default deployment). For
  per-tenant cost questions, that's the source of truth.
- **Rotating a key:** issue a new one via the LiteLLM admin UI
  (`https://<gateway-host>/ui/`) → Virtual Keys → Create Key, deploy to the
  application, then revoke the old one. Keys don't expire on their own.

---

## Quick smoke test

```bash
KEY=<your-virtual-key>

curl -s https://<gateway-host>/v1/chat/completions \
  -H "Authorization: Bearer $KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "llama3.1",
    "messages": [{"role":"user","content":"reply: ok"}],
    "max_tokens": 5,
    "metadata": {"tenant_id":"smoke-test"}
  }'
```

A `200` with a model response confirms the path end-to-end.
