# Integration guide — Kleem, PMS, Qams

How each product connects to the shared LLM platform at **`https://llm.kleem.io`**.

The gateway is OpenAI wire-compatible. Any client that targets the OpenAI API works by setting two things: the base URL, and the API key.

---

## Endpoint

```
Base URL:           https://llm.kleem.io/v1
Chat completions:   POST https://llm.kleem.io/v1/chat/completions
Models list:        GET  https://llm.kleem.io/v1/models
Health:             GET  https://llm.kleem.io/health/liveliness
```

TLS via `*.kleem.io` ACM cert. The gateway terminates TLS, authenticates the
virtual key, routes to one of the three hosted models, streams tokens back
unbuffered, and logs cost + latency telemetry.

---

## Models

Three local models share one T4 GPU (16 GB VRAM) via Ollama hot-swap: only
one is GPU-resident at any moment; the active one swaps when a request
targets a different model. First request after a swap is slower (~10–20 s
warm-up); subsequent calls are fast.

| Model name (use in the `model` field) | Sweet spot |
|---|---|
| `llama3.1` | General chat, conversational features, low-latency replies (Llama 3.1 8B) |
| `gemma4` | Drafting, summarization, longer-form writing (Google Gemma 4 latest) |
| `qwen2.5-coder` | Code generation, structured extraction, technical text (Qwen 2.5 Coder 7B) |

Re-scoping any key to a different (or additional) model is a config change in
the LiteLLM admin UI (`https://litellm.kleem.io/ui/`) — no app redeploy.

---

## Authentication

Each app has its own virtual key, bound to one model by default. **Never
commit a key to the repo.** Pull from AWS SSM at app startup or read from
the app's own deploy env:

```bash
aws ssm get-parameter --region ap-south-1 \
  --name /llm-platform/prod/apps/<app>/api_key \
  --with-decryption --query Parameter.Value --output text
```

Default starting assignment (re-scope freely in the LiteLLM UI):

| App | SSM parameter path | Model |
|---|---|---|
| Kleem | `/llm-platform/prod/apps/kleem/api_key` | `llama3.1` |
| PMS | `/llm-platform/prod/apps/pms/api_key` | `gemma4` |
| Qams | `/llm-platform/prod/apps/qams/api_key` | `qwen2.5-coder` |

A request to a model the key isn't scoped to returns `401`.

---

## Tenant attribution (mandatory for tenant-scoped products)

Tenant-scoped products **must** send `metadata.tenant_id` on every request.
It lands in the gateway log alongside the virtual key, model, cost, and
latency — that's how we attribute spend per tenant.

```json
{
  "model": "llama3.1",
  "messages": [{"role": "user", "content": "…"}],
  "metadata": {"tenant_id": "acme-co"}
}
```

---

## Per-product wiring

### Kleem (TypeScript)

```ts
import OpenAI from "openai";

const llm = new OpenAI({
  baseURL: "https://llm.kleem.io/v1",
  apiKey: process.env.LLM_PLATFORM_KEY,        // pulled from SSM at boot
});

// Streaming chat turn
const turn = await llm.chat.completions.create({
  model: "llama3.1",
  messages,
  stream: true,
  // @ts-expect-error - metadata passthrough
  metadata: { tenant_id: session.tenantId },
});

for await (const chunk of turn) {
  const piece = chunk.choices[0]?.delta?.content ?? "";
  // pipe to TTS / UI / etc.
}

// One-shot non-stream (e.g. post-call summary)
const summary = await llm.chat.completions.create({
  model: "llama3.1",
  messages: [
    { role: "system", content: "Summarize the call in 3 bullets." },
    { role: "user", content: transcript },
  ],
  // @ts-expect-error
  metadata: { tenant_id: call.tenantId },
});
```

### PMS (TypeScript)

```ts
import OpenAI from "openai";

const llm = new OpenAI({
  baseURL: "https://llm.kleem.io/v1",
  apiKey: process.env.LLM_PLATFORM_KEY,
});

const draft = await llm.chat.completions.create({
  model: "gemma4",
  messages: [
    { role: "system", content: "You are a property-listing copywriter." },
    { role: "user", content: prompt },
  ],
  // @ts-expect-error
  metadata: { tenant_id: property.tenantId, feature: "listing_draft" },
});
```

### Qams (Python)

```python
import os
from openai import OpenAI

llm = OpenAI(
    base_url="https://llm.kleem.io/v1",
    api_key=os.environ["LLM_PLATFORM_KEY"],
)

resp = llm.chat.completions.create(
    model="qwen2.5-coder",
    messages=[
        {"role": "system", "content": rubric_prompt},
        {"role": "user", "content": retrieved_evidence_block},
    ],
    extra_body={"metadata": {"tenant_id": tenant_id, "feature": "inspection"}},
)
verdict = resp.choices[0].message.content
```

---

## Streaming (SSE)

Set `stream: true` — token-level delivery is preserved end-to-end (gateway,
ALB, and Ollama all flush per chunk). Client disconnects propagate as
upstream cancellation, freeing the GPU slot immediately.

```bash
curl -N https://llm.kleem.io/v1/chat/completions \
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
| `500` / `502` | Backend failure — gateway should fall back automatically (each model falls back to a peer model); if you see persistent 502, something deeper is wrong |
| `504` | Backend timed out at the ALB. **Most common cause: the EC2 was stopped by the cost-saving schedule (22:00 IST weekdays + weekends).** Start with `aws ec2 start-instances --instance-ids i-07b8afbda6a412aa3 --region ap-south-1` or wait for the 08:00 IST start. ~1 minute to recover (model cache survives) |

---

## First-call latency

On a cold model (first request after a swap or a fresh box):

| Scenario | TTFT |
|---|---|
| Box just started, no model loaded | ~30–60 s (model loads into VRAM from EBS) |
| Box warm, different model active | ~10–20 s (swap) |
| Box warm, requested model already active | ~200–800 ms |

If you're benchmarking or building anything latency-sensitive, send a warm-up
request 5–10 s before the real one — that puts the model in VRAM and the
real call hits the fast path.

---

## Operational notes

- **Cost-aware schedule:** the EC2 stops at 22:00 IST weekdays + all weekend; starts at 08:00 IST weekdays. ~60% savings vs always-on. Plan demos accordingly. Override per [CLAUDE.md §10](../CLAUDE.md).
- **Logs and traces:** every request is logged at the gateway + traced in Langfuse (`https://langfuse.kleem.io`). For per-tenant cost questions, that's the source of truth.
- **Rotating a key:** issue a new one via the LiteLLM admin UI (`https://litellm.kleem.io/ui/`) → Virtual Keys → Create Key, deploy to the app, then revoke the old one. Keys don't expire on their own.

---

## Quick smoke test

```bash
# Replace <app> with kleem | pms | qams
KEY=$(aws ssm get-parameter --region ap-south-1 \
  --name /llm-platform/prod/apps/<app>/api_key \
  --with-decryption --query Parameter.Value --output text)

# Use the model that <app> is scoped to (llama3.1 for kleem, gemma4 for pms,
# qwen2.5-coder for qams by default)
curl -s https://llm.kleem.io/v1/chat/completions \
  -H "Authorization: Bearer $KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "llama3.1",
    "messages": [{"role":"user","content":"reply: ok"}],
    "max_tokens": 5,
    "metadata": {"tenant_id":"smoke-test"}
  }'
```

A 200 with a model response confirms the path end-to-end.
