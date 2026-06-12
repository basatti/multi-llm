# Integration guide — Kleem, PMS, Qams

How each product connects to the shared LLM platform at **`https://llm.kleem.io`**.

The gateway is OpenAI wire-compatible. Any client that targets the OpenAI API (the official SDK, LangChain, LlamaIndex, plain HTTP, the Anthropic SDK in OpenAI-compat mode, etc.) works by changing two things: the base URL, and the API key.

---

## Endpoint

```
Base URL:           https://llm.kleem.io/v1
Chat completions:   POST https://llm.kleem.io/v1/chat/completions
Models list:        GET  https://llm.kleem.io/v1/models
Health:             GET  https://llm.kleem.io/health/liveliness
```

TLS via `*.kleem.io` ACM cert. The gateway terminates TLS, authenticates the
virtual key, routes to a physical backend (currently vLLM serving
Qwen/Qwen2.5-7B-Instruct-AWQ on a g4dn.xlarge, plus frontier fallback), logs
cost + latency telemetry, and streams tokens back unbuffered.

---

## Authentication

Each app has its own virtual key — scoped to specific logical model names,
budgeted, revocable independently. **Never commit a key to the repo.** Pull
from AWS SSM at app startup or read from the app's own env:

```bash
aws ssm get-parameter --region ap-south-1 \
  --name /llm-platform/prod/apps/<app>/api_key \
  --with-decryption --query Parameter.Value --output text
```

Per-app SSM paths and the logical model names each key is scoped to:

| App | SSM parameter path | Allowed logical models |
|---|---|---|
| Kleem | `/llm-platform/prod/apps/kleem/api_key` | `chat-default`, `kleem-realtime`, `summarize-cheap` |
| PMS | `/llm-platform/prod/apps/pms/api_key` | `chat-default`, `summarize-cheap` |
| Qams | `/llm-platform/prod/apps/qams/api_key` | `chat-default`, `qams-rag`, `summarize-cheap` |

A call to a logical name the key isn't scoped to returns `401`.

---

## Logical model names

Apps **only** request logical names. The gateway maps logical → physical at
request time; the physical backend can change without any product redeploy.

| Logical name | Tier | Use for |
|---|---|---|
| `chat-default` | general | Drafting, summarization, classification, conversational features |
| `kleem-realtime` | low-latency (TTFT ≤ 400 ms target) | Kleem's voice path; pinned warm capacity |
| `qams-rag` | quality (accuracy-first) | Qams accreditation RAG, frontier-grade quality |
| `summarize-cheap` | batch/async | Post-call summaries, transcript analysis, anything latency-insensitive |

Don't request raw physical model names like `Qwen/Qwen2.5-7B-Instruct-AWQ` —
those will change as the platform scales, and pinning to one defeats the
gateway's whole purpose.

---

## Tenant attribution (mandatory for tenant-scoped products)

Tenant-scoped products **must** include `metadata.tenant_id` on every request.
It lands in the gateway log alongside the virtual key, logical model, cost,
and latency — that's how we attribute spend per tenant.

```json
{
  "model": "chat-default",
  "messages": [{"role": "user", "content": "…"}],
  "metadata": {"tenant_id": "acme-co"}
}
```

Missing-tag requests are flagged today; will be rejected once dashboards bake.

---

## Per-product wiring

### Kleem (TypeScript)

Two paths — realtime voice and post-call async — using different logical names:

```ts
import OpenAI from "openai";

const llm = new OpenAI({
  baseURL: "https://llm.kleem.io/v1",
  apiKey: process.env.LLM_PLATFORM_KEY,        // pulled from SSM at boot
});

// Voice turn: low-latency, pinned warm capacity, frontier fallback on TTFT miss
const turn = await llm.chat.completions.create({
  model: "kleem-realtime",
  messages,                                    // assembled by orchestration
  stream: true,
  // @ts-expect-error - metadata passthrough
  metadata: { tenant_id: session.tenantId },
});

for await (const chunk of turn) {
  const piece = chunk.choices[0]?.delta?.content ?? "";
  // pipe to TTS at sentence/clause boundaries; close the stream on barge-in
  // — cancellation propagates back to vLLM (architecture.md §7.1)
}

// Post-call summary: queued, cheapest tier, no streaming
const summary = await llm.chat.completions.create({
  model: "summarize-cheap",
  messages: [
    { role: "system", content: "Summarize the call in 3 bullet points." },
    { role: "user", content: transcript },
  ],
  // @ts-expect-error
  metadata: { tenant_id: call.tenantId },
});
```

For agentic / stateful flows (sessions, memory, tool calls) go through
**orchestration** instead of the gateway directly — that's reached via SSM
port-forward today (`localhost:8000/v1/sessions`) and will be exposed under
its own subdomain once the contract stabilises.

### PMS (request/response features)

PMS is predominantly stateless one-shot completions — direct gateway calls
are sanctioned for this case (architecture.md §3, §7.4):

```ts
import OpenAI from "openai";

const llm = new OpenAI({
  baseURL: "https://llm.kleem.io/v1",
  apiKey: process.env.LLM_PLATFORM_KEY,
});

const draft = await llm.chat.completions.create({
  model: "chat-default",
  messages: [
    { role: "system", content: "You are a property-listing copywriter." },
    { role: "user", content: prompt },
  ],
  // @ts-expect-error
  metadata: { tenant_id: property.tenantId, feature: "listing_draft" },
});
```

For long documents (e.g. summarizing all maintenance reports for a quarter)
use `summarize-cheap` instead of `chat-default`.

### Qams (Python — AI Inspector)

Accuracy-first quality tier; frontier-backed for now, may shift to a local
larger model once Phase 3 benchmarks justify it:

```python
import os
from openai import OpenAI

llm = OpenAI(
    base_url="https://llm.kleem.io/v1",
    api_key=os.environ["LLM_PLATFORM_KEY"],
)

resp = llm.chat.completions.create(
    model="qams-rag",
    messages=[
        {"role": "system", "content": rubric_prompt},
        {"role": "user", "content": retrieved_evidence_block},
    ],
    extra_body={"metadata": {"tenant_id": tenant_id, "feature": "inspection"}},
)
verdict = resp.choices[0].message.content
```

The retrieval (vector search, provenance stamping, rubric assembly) stays in
Qams's existing FastAPI service for now — refactor target is to move it into
shared orchestration once that's stable.

---

## Streaming (SSE)

The same `stream: true` flag any OpenAI SDK exposes. Token-level delivery is
preserved end-to-end (gateway, ALB, and the inference engine all flush per
chunk). Client disconnects propagate as upstream cancellation, freeing GPU
slots immediately — important on Kleem's voice path for barge-in handling.

```bash
curl -N https://llm.kleem.io/v1/chat/completions \
  -H "Authorization: Bearer $LLM_PLATFORM_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "chat-default",
    "messages": [{"role": "user", "content": "hi"}],
    "stream": true,
    "metadata": {"tenant_id": "demo"}
  }'
```

---

## Errors you'll see

| Code | Meaning |
|---|---|
| `401` | Missing or invalid `Authorization: Bearer …`, OR the key isn't scoped to the requested logical model |
| `429` | Per-key rate limit or budget cap hit. Check the key's budget at the LiteLLM admin UI |
| `400` | Malformed request — usually `messages` shape or unknown logical model |
| `500` / `502` | Backend failure — gateway should fall back automatically for routes that have a fallback chain; if you see 502 something deeper is wrong |
| `504` | Backend timed out at the ALB. **Most common cause: the EC2 was stopped by the scheduled cost-saving stop (22:00 IST weekdays + weekends).** Start it manually with `aws ec2 start-instances --instance-ids i-07b8afbda6a412aa3 --region ap-south-1` or wait for the 08:00 IST start. ~1 minute to recover after start (model cache survives) |

---

## Operational notes

- **Cost-aware schedule:** the EC2 stops at 22:00 IST weekdays + all weekend; starts at 08:00 IST weekdays. ~60% cost saving vs always-on, but plan demos and on-call accordingly. Override per [CLAUDE.md §10](../CLAUDE.md).
- **TLS / cert:** `*.kleem.io` ACM cert; no client-side cert config needed.
- **Logs and traces:** every request lands in the gateway log + Langfuse traces (`https://langfuse.kleem.io`). For per-tenant cost questions, that's the source of truth.
- **Rotating a key:** issue a new key via the LiteLLM admin UI (`https://litellm.kleem.io/ui/`) or the management API; deploy to the app; revoke the old one. Keys never expire on their own.

---

## When to NOT call the gateway directly

The gateway is the right destination for **stateless one-shot completions**.
Anything that needs sessions, memory, RAG with provenance, or multi-step tool
loops belongs in **orchestration**, not in the product (architecture.md §3):

- Don't store conversation history in the product DB and replay it on every
  turn — that's what orchestration's `/v1/sessions` is for.
- Don't paste raw prompts together in the product — that's what the
  Langfuse template + orchestration's `/v1/apps/{id}/invoke` is for.
- Don't implement tool calling loops in the product — orchestration manages
  those.

The orchestration service contract is documented separately; reach it via
`aws ssm start-session ... AWS-StartPortForwardingSession` on `localhost:8000`
until it's publicly exposed.

---

## Quick smoke test

```bash
# Replace <app> with kleem | pms | qams
KEY=$(aws ssm get-parameter --region ap-south-1 \
  --name /llm-platform/prod/apps/<app>/api_key \
  --with-decryption --query Parameter.Value --output text)

curl -s https://llm.kleem.io/v1/chat/completions \
  -H "Authorization: Bearer $KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "chat-default",
    "messages": [{"role":"user","content":"reply: ok"}],
    "max_tokens": 5,
    "metadata": {"tenant_id":"smoke-test"}
  }'
```

A 200 with a Qwen response confirms the path end-to-end.
