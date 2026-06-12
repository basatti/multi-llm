# 1TechHub LLM Platform — Architecture & Implementation Plan

**Status:** Draft for review
**Owner:** AI & Innovation — Basil A. Satti
**Date:** June 2026
**Scope:** Shared LLM serving platform for Kleem, PMS, and Qams on AWS GPU infrastructure

---

## 1. Executive summary

1TechHub currently powers AI features across its SaaS products (Kleem, PMS, Qams) through direct frontier-model API integrations, with API keys embedded per service. This works but does not scale organizationally or financially: every product re-implements model access, cost is opaque and unattributable, latency-critical features (Kleem voice) compete with batch workloads, and we have no path to self-hosted models for cost control, fine-tuning, or data residency.

This document defines a four-layer LLM platform: a **stateless GPU inference layer** ("LLM repo") running open-weight models on AWS, fronted by a **gateway** that unifies routing, auth, budgets, and frontier-API fallback, with a separate **stateful orchestration layer** owning sessions, memory, RAG, and agent loops, consumed by the **product layer**.

The central architectural decision: **the inference layer is fully isolated from all stateful and agentic concerns.** Inference nodes receive messages and return tokens — nothing else. Sessions, memory, tool execution, and conversation state live exclusively in the orchestration layer. This isolation is what allows independent scaling, model lifecycle management without product changes, contained blast radius, and a single governance choke point.

Migration is incremental: existing frontier API usage is re-pointed at the gateway first (no behavior change), then traffic shifts to local models feature-by-feature as quality and cost are validated.

---

## 2. Goals and non-goals

### Goals

1. **Single front door for all model access.** Every LLM call from every product and microservice flows through one gateway, regardless of whether it resolves to a local GPU or a frontier API.
2. **Self-hosted inference capability.** Run multiple open-weight models (and fine-tuned variants) on AWS GPU instances with an OpenAI-compatible interface.
3. **Strict layer isolation.** Inference is stateless; orchestration is stateful; products never talk to GPUs directly.
4. **Per-product cost attribution and budgets.** Answer "what did Qams's AI features cost last month, local vs. frontier?" from gateway telemetry alone.
5. **Latency tiering.** Kleem's realtime voice path gets pinned warm capacity and hard TTFT targets; batch/async workloads use cheap spare capacity.
6. **Graceful degradation.** Local GPU failures, cold starts, or capacity spikes fall back to frontier APIs transparently; no product-visible outage.
7. **Incremental migration.** No big-bang cutover. Frontier APIs remain a first-class routed backend indefinitely.

### Non-goals

- Building a custom inference engine (we use vLLM).
- Building a custom gateway from scratch (we adopt and harden an existing one).
- A single shared "memory" abstraction forced across all products — orchestration starts shared but is expected to specialize per product.
- Model training infrastructure. Fine-tuning pipelines are out of scope for this phase; the platform only needs to *serve* LoRA adapters produced elsewhere.

---

## 3. Architecture overview

Four layers, strictly ordered. Calls only flow downward; no layer reaches around another.

```
┌─────────────────────────────────────────────────────────┐
│  4. PRODUCT LAYER                                       │
│     Kleem · PMS · Qams · other microservices            │
└───────────────┬─────────────────────────┬───────────────┘
                │  agentic / stateful     │  one-shot
                ▼                         │  completions
┌───────────────────────────────┐         │
│  3. ORCHESTRATION (stateful)  │         │
│     Sessions · memory · RAG   │         │
│     Tool calling · agent loops│         │
└───────────────┬───────────────┘         │
                ▼                         ▼
┌─────────────────────────────────────────────────────────┐
│  2. GATEWAY / ROUTER (stateless)                        │
│     Auth (virtual keys) · routing · rate limits         │
│     Budgets · fallback · retries · observability        │
└──────────┬──────────────────────────────┬───────────────┘
           ▼                              ▼
┌─────────────────────────┐   ┌───────────────────────────┐
│  1a. LLM REPO (local)   │   │  1b. FRONTIER APIs        │
│  vLLM on AWS GPU        │   │  Anthropic / OpenAI /     │
│  Stateless, OpenAI-     │   │  Bedrock — fallback,      │
│  compatible, multi-LoRA │   │  overflow, quality tier   │
└─────────────────────────┘   └───────────────────────────┘
```

### Layer responsibilities at a glance

| Layer | State | Knows about | Never knows about |
|---|---|---|---|
| Inference (LLM repo) | None | Messages in, tokens out, LoRA adapter IDs | Callers, sessions, tenants, tools |
| Gateway | Routing/limit counters only (Redis) | Virtual keys, budgets, logical→physical model map, backends | Conversations, memory, business logic |
| Orchestration | Sessions, memory, RAG indexes | Products, tenants, tools, conversation history | Physical model deployments, GPU topology |
| Products | Product domain state | Their own features; logical model names | Which physical model served a request |

---

## 4. Layer 1 — Inference ("LLM repo")

### 4.1 Serving engine

- **Engine:** vLLM, exposing the OpenAI-compatible `/v1/chat/completions` (and `/v1/completions`) endpoints. SGLang is the evaluated alternative if vLLM hits a wall; the OpenAI wire contract makes the engine swappable.
- **Contract:** The inference layer is *dumb and stateless*. A request contains messages, sampling parameters, and optionally a LoRA adapter name. There is no database access, no session lookup, no tool execution, no retrieval. Tokens stream out; the slot is freed.
- **Streaming:** Server-sent events end to end. Every consumer upstream must pass tokens through rather than buffer-then-forward — this is a platform-wide invariant required by Kleem's voice path.

### 4.2 Multi-model strategy: base models + LoRA, not one deployment per model

The dominant cost lever. Instead of one GPU deployment per product-specific model:

- Run a small number of **base models** (e.g., one strong multilingual 8–14B for general chat/summarization, one larger model if a use case demands it).
- Product-specific fine-tunes are served as **hot-swappable LoRA adapters** on the shared base via vLLM's multi-LoRA serving. Dozens of logical "models" per GPU instead of one.
- Apply **quantization** (FP8 on Hopper/Ada-class GPUs, AWQ otherwise) to increase concurrency per card or fit larger bases.
- Arabic/English bilingual capability is a hard requirement for model selection given our market; candidate bases must be benchmarked on Arabic tasks before adoption.

### 4.3 AWS instance strategy

| Workload | Model class | Instance family | Notes |
|---|---|---|---|
| Kleem realtime (voice turns) | Small/fast 7–14B, quantized | `g6e` (L40S) or `g5` (A10G) | Pinned warm replicas, never scale-to-zero |
| General product features (PMS, Qams chat/summarize) | 7–34B | `g5` / `g6e` | Warm baseline of 1 replica per active model |
| Heavy RAG / long-context (Qams inspection) | 34–70B+ | `p4d` (A100) / `p5` (H100) only if justified | Validate demand on frontier fallback first |
| Batch/async (summaries, analytics, embeddings) | Smallest viable | Spare capacity on the above; Spot where tolerable | Queue-based, latency-insensitive |

**Autoscaling rules:**
- Scale on **queue depth and TTFT**, not CPU/GPU utilization alone.
- Maintain a **warm minimum of one replica per actively routed model**. Cold starts cost tens of seconds to minutes (weight loading); they are absorbed by the gateway's frontier fallback, never by the user.
- Scale-to-zero is permitted only for low-traffic models on async paths.

**Bedrock checkpoint:** Before committing to large-GPU spend (`p4d`/`p5`), re-evaluate AWS Bedrock's open-weight catalog. Self-hosting earns its keep with custom LoRAs, data-residency constraints, or sustained high volume; if a use case has none of those, Bedrock (routed through the same gateway) may be the cheaper operational answer.

### 4.4 Repository and deployment model

- A single `llm-repo` (infrastructure-as-code + model manifests): Terraform for AWS resources, container definitions for vLLM, a manifest mapping model IDs → weights (S3) → LoRA adapters → instance class → replica policy.
- CI deploys model changes without touching gateway or orchestration. Adding a model or adapter is a manifest change + gateway route update, zero product code changes.
- Model weights stored in S3 in-region; nodes pull on boot (or from a warm EBS/FSx cache to cut cold-start time).

---

## 5. Layer 2 — Gateway / router

### 5.1 Responsibilities

1. **Logical model routing.** Products request logical names (`kleem-realtime`, `chat-default`, `qams-rag`, `summarize-cheap`); the gateway maps these to physical backends. Re-pointing a logical name is a config change, invisible to products.
2. **Auth via virtual keys.** Each product/service receives a gateway-issued virtual key. Real provider credentials (Anthropic, OpenAI, Bedrock IAM) live only in the gateway's secret store. Keys are scoped, budgeted, and revocable per product and per tenant where needed.
3. **Rate limits and budgets.** Request/token/spend caps per virtual key. A runaway agent loop in one product cannot exhaust GPU capacity or frontier spend for the others.
4. **Fallback chains, retries, load balancing.** Per logical name: ordered backend list with timeout and error policies. Example: `kleem-realtime` → local vLLM (TTFT timeout 400 ms) → fast frontier model.
5. **Model lifecycle: enable/disable.** Enabling or disabling a model is a gateway routing change, not a deployment event. Soft disable: remove the physical backend from the logical name's route — new requests immediately resolve to the next backend in the fallback chain, in-flight streams complete, products see nothing (they only know logical names). Hard disable: after draining, scale the vLLM deployment to zero via the `llm-repo` manifest to release GPU spend. Per-app revocation is handled by key scoping. Two enforced rules: every logical name must have a fallback chain (a disabled model with no fallback is an outage), and disable ≠ delete — manifests and weights are retained so re-enable is a config flip plus warm-up.
6. **Observability and cost attribution.** Every request logged with virtual key, logical model, resolved backend, token counts, TTFT, total latency, and computed cost. This is the platform's single source of truth for "local vs. frontier" economics.
7. **Optional, later:** exact-match/semantic response caching; centralized input/output guardrails.

### 5.2 Implementation choice

**Adopt LiteLLM Proxy (self-hosted) as the initial gateway.** It provides OpenAI-compatible ingress, 100+ provider backends (vLLM is treated as just another OpenAI-compatible endpoint), virtual keys, budgets, routing, fallbacks, retries, and caching out of the box via YAML configuration. **Engagement model: deploy, configure, and harden only — no forking or custom gateway code in Phases 0–2.** App registration and key issuance use LiteLLM's built-in admin UI and management API (see §6.4).

**Security hardening is mandatory, not optional.** A supply-chain attack compromised LiteLLM releases 1.82.7/1.82.8 on PyPI in March 2026 (clean release: ≥1.83.0). The gateway holds all real provider credentials and is therefore the highest-value target in the platform. Required controls:

- Pin to an audited, known-good version; install from verified artifacts; review dependency diffs on upgrade.
- Run in an isolated subnet with locked-down egress (only declared provider endpoints and the vLLM service).
- Provider credentials in AWS Secrets Manager, injected at runtime, never in config files or images.
- Minimum two replicas behind an internal ALB/NLB; the gateway itself must not be a single point of failure.
- Redis (ElastiCache) for shared rate-limit counters and optional caching — the proxy processes stay stateless.

**Latency escape hatch:** If gateway overhead on Kleem's realtime path proves measurable against the TTFT budget, evaluate a faster Go-based gateway (e.g., Bifrost) *for that path only*, keeping LiteLLM for everything else. Decide from measured TTFT data, not preemptively.

### 5.3 Design invariant

The gateway is **stateless and conversation-blind**. It knows keys, budgets, routes, and backends. The moment session or memory logic appears in the gateway, the isolation this architecture exists to protect has been broken.

---

## 6. Layer 3 — Orchestration (stateful)

### 6.1 Responsibilities

- **Session state:** conversation history keyed by `product + tenant + session_id`, held server-side.
- **Memory:** short-term (session window management, summarization-on-overflow) and long-term (per-tenant/user persistent memory) as products require it.
- **RAG:** retrieval pipelines over product corpora (e.g., Qams accreditation documents) with provenance tracking.
- **Tool calling and agent loops:** executing tools, feeding results back, managing multi-step plans — all the slow, I/O-bound work that must never sit on a GPU node.
- **Prompt assembly:** system prompts, retrieved context, memory, and history are composed here; products send intents and payloads, not raw prompts, for agentic features.

### 6.2 Structure

- **Start as one shared orchestration service** (with clean per-product modules) to avoid triple-building session plumbing.
- **Expect and plan for per-product specialization.** Kleem's voice-turn loop (barge-in, sub-second budgets, TTS coupling) and Qams's inspection pipeline (long documents, provenance, locked rubrics) will diverge. The shared core should be session storage, memory primitives, and the gateway client; the loops on top are product-owned.
- All model calls from orchestration go **through the gateway** using orchestration's (or the originating product's) virtual key — orchestration never holds provider credentials and never addresses vLLM directly.

### 6.3 State storage

- Session/conversation state: Redis (hot) + a durable store (PostgreSQL or MongoDB, aligned with each product's existing stack) for recovery and audit.
- Vector retrieval: per-product choice (Qams already on Atlas Vector Search); orchestration treats retrieval backends as pluggable.

### 6.4 App registry and prompt management

Application onboarding spans three systems, and the responsibilities must not blur:

- **Gateway (LiteLLM):** app identity, virtual key issuance, budgets, rate limits, model access scope. Managed via LiteLLM's built-in admin UI and management API. The gateway remains conversation-blind.
- **Prompt management (Langfuse, self-hosted):** general context / system prompts and versioned prompt templates. Langfuse is adopted rather than built: it provides versioning, production labels, promotion/rollback, runtime fetching with SDK-side caching, and a UI where prompt changes ship without app redeploys. It is MIT-licensed, deploys in our VPC (official AWS Terraform modules exist), and the LiteLLM + Langfuse pairing is an established open-source LLMOps pattern. Langfuse additionally provides tracing/observability linked to prompt versions, which directly serves the quality-signal loop in §9.
- **Orchestration (app registry — custom, deliberately thin):** the glue and the behavioral policy Langfuse does not model — agent configuration (allowed tools, memory policy, logical model name, sampling defaults) and governance metadata.

**Registration flow.** Registering an app is one operation exposed by the orchestration service that fans out to all three systems: it creates a virtual key (LiteLLM management API), initializes the app's prompt namespace (Langfuse API), and writes an **app profile** row in the orchestration database (PostgreSQL), linked by app ID. Every registration records owner and cost center — this metadata is mandatory and is what turns the key list into a governance surface.

**App profile contents (custom registry):**

| Field | Purpose |
|---|---|
| `app_id`, owner, cost center | Identity and governance |
| Virtual key reference | Link to gateway identity (key itself stays in the gateway) |
| Langfuse prompt namespace | Link to the app's prompts/templates (content lives in Langfuse) |
| Agent config | Allowed tools, memory policy, logical model name, sampling defaults |

**Runtime contract.** Apps call orchestration with their virtual key, a `template_id`, and variables — **apps send intents and payloads, never raw prompts** (consistent with §6.1). Orchestration resolves the app profile, fetches the production-labeled template version from Langfuse (cached), assembles the prompt (template + context + memory + retrieved content), and calls the gateway. Direct gateway calls remain available for simple one-shot completions that need no template or context.

**Why this split:**
- Prompt and template changes ship without app redeploys; Langfuse versioning and labels enable instant rollback and staged promotion (dev → staging → production labels per environment).
- Every production prompt is visible and reviewable in one place — an audit and quality surface, not just convenience. Non-engineers can iterate on prompts in the Langfuse UI without a deployment cycle.
- Template versions are linked to traces, so a template change can be benchmarked before promotion, aligning with the per-feature quality gates in §9.

**Build scope (deliberately minimal):** one app-profile table, one registration endpoint that fans out to LiteLLM and Langfuse, and the runtime resolution path in orchestration. No custom prompt store, no custom versioning, no custom key-management UI, and no custom template UI — LiteLLM and Langfuse UIs cover both halves. Langfuse evaluation gaps (no automated evals on prompt changes, no approval workflows in OSS) are accepted for now; the eval gate in §11 remains a manual/sampled process initially.

---

## 7. Layer 4 — Product integration patterns

### 7.1 Kleem (realtime voice agent) — two distinct paths

**Realtime path (the voice loop):**
- Kleem's TypeScript worker holds a streaming connection to orchestration per active call, keyed by `session_id`. The worker keeps no conversation state locally — orchestration owns it — so workers scale horizontally and dropped connections recover cleanly.
- Orchestration manages the turn: history, memory, tool calls, prompt assembly, then streams the completion from the gateway.
- **Hard TTFT budget (target ≤ 400 ms to first token at the gateway).** Routed to a pinned, warm, quantized small model. On TTFT timeout, the gateway fails over to a fast frontier model — a slightly costlier fast answer always beats a cheap slow one in voice.
- **Streaming is end-to-end:** GPU → gateway → orchestration → TS worker → TTS, with TTS fed at sentence/clause boundaries so audio begins while generation continues.
- **Cancellation propagates.** On barge-in, the worker closes the stream; orchestration and gateway propagate the abort so vLLM frees the sequence immediately. Interrupted turns must not keep burning GPU.

**Async path (post-call work):**
- Summaries, transcript analysis, intent extraction, quality scoring: queued jobs straight to the gateway as one-shot completions on the cheapest suitable model. No session, no orchestration, no latency constraint. These must never share the pinned realtime capacity.

### 7.2 PMS

- Predominantly request/response features (drafting, summarization, classification): direct gateway calls with logical names on the standard tier.
- Any future conversational/assistant feature goes through orchestration like the others.

### 7.3 Qams (AI Inspector)

- The AI Inspector pipeline (RAG over accreditation corpora, version-pinned retrieval, locked rubric, provenance stamping) lives in orchestration (or remains in its existing FastAPI microservice, refactored to call the gateway instead of providers directly — acceptable interim state).
- Routed to a quality-tier logical model (`qams-rag`), which may resolve to a larger local model or a frontier model depending on validated accuracy; accuracy outranks cost here.
- Async inspection jobs use the batch tier.

### 7.4 General microservices

Any microservice needing AI gets a virtual key and calls the gateway with a logical model name. No service ever receives provider API keys again.

---

## 8. Network and deployment topology (AWS)

- **Single VPC (per environment), three tiers of subnets:**
  - *Product/app subnets* — existing services.
  - *Platform subnet* — gateway replicas + orchestration service + Redis/ElastiCache, behind internal load balancers.
  - *GPU subnet* — vLLM nodes, isolated; ingress only from the gateway security group; egress only to S3 (weights) and telemetry.
- **No public ingress to gateway or GPU nodes.** Products reach the gateway over internal DNS (e.g., `llm-gateway.internal.1techhub`).
- **Compute:** GPU nodes on EKS with the NVIDIA device plugin (preferred, aligns with manifest-driven deploys and autoscaling via Karpenter), or ECS/ASG if the team prefers lower Kubernetes overhead initially.
- **Secrets:** AWS Secrets Manager for provider credentials and the gateway's master key; IAM roles for service-to-service auth where applicable.
- **Environments:** `dev` (CPU or single small GPU + frontier-heavy routing), `staging`, `prod`. Routing tables are per-environment config.

---

## 9. Observability and cost model

All telemetry hangs off the gateway because every request crosses it.

**Per-request fields:** virtual key (product/tenant), logical model, resolved backend, prompt/completion tokens, TTFT, total latency, status, fallback-triggered flag, computed cost.

**Dashboards (minimum):**
1. Cost per product per day, split local vs. frontier — the migration scoreboard.
2. TTFT p50/p95/p99 per logical model — Kleem's SLO view.
3. GPU utilization vs. queue depth per deployment — scaling signal.
4. Fallback rate per logical name — local capacity/health signal; a rising fallback rate is the earliest warning that GPU capacity or health is degrading.
5. Error and retry rates per backend.

**Quality signal:** sampled completions per feature routed into a lightweight eval loop (even manual review initially) before any feature's traffic shifts from frontier to local. Cost data without quality data leads to false savings.

---

## 10. Security and governance summary

- Real provider credentials exist **only** in the gateway's secret store. Products and orchestration hold revocable virtual keys.
- Per-key budgets and rate limits enforce blast-radius containment by default.
- GPU subnet accepts traffic only from the gateway; the inference layer is unreachable from products even by mistake.
- Gateway software supply chain: version pinning, artifact verification, dependency review on every upgrade (lesson of the March 2026 LiteLLM incident).
- Data residency: self-hosted models keep prompts/completions in-region in our VPC; routing policy can pin sensitive logical names (e.g., government-adjacent workloads) to **local-only** backends with no frontier fallback. This must be an explicit per-route flag.
- Audit: gateway request logs retained per compliance requirements (align retention with PDPL obligations for any personal data in prompts; prefer logging metadata over full prompt bodies for sensitive routes).

---

## 11. Rollout plan

**Phase 0 — Gateway in front of what exists (1–2 weeks)**
Deploy hardened LiteLLM proxy (2 replicas + Redis). Issue virtual keys to Kleem, PMS, Qams, and microservices. Re-point all existing frontier API calls at the gateway with logical names. *No model changes.* Outcome: unified telemetry, budgets, and the cost baseline.

**Phase 1 — First local model on the async tier (2–4 weeks)**
Stand up the `llm-repo`: one vLLM deployment, one quantized 8–14B bilingual base, on `g5`/`g6e`. Route low-risk async workloads (Kleem post-call summaries, PMS summarization) to it with frontier fallback. Deploy self-hosted Langfuse and stand up the minimal app registry (§6.4): app profiles, owner/cost-center metadata, first versioned prompt templates in Langfuse. Validate quality via sampled evals; validate cost via dashboard 1.

**Phase 2 — Kleem realtime path (3–5 weeks, overlaps Phase 1)**
Stand up orchestration's session service for Kleem voice turns (server-side state, streaming, cancellation). Pin warm replicas for `kleem-realtime`, enforce the 400 ms TTFT budget with frontier failover. Shift live traffic gradually (shadow → percentage rollout), watching TTFT p95/p99 and fallback rate.

**Phase 3 — Qams and RAG workloads**
Refactor the AI Inspector to call the gateway. Benchmark local candidates against the frontier baseline on accuracy (rubric adherence, provenance fidelity) before shifting any traffic. Accuracy gates the migration; cost does not.

**Phase 4 — LoRA serving and specialization**
Introduce multi-LoRA serving for the first product fine-tune. Split orchestration per product where the shared loops have visibly diverged. Re-run the Bedrock checkpoint before any large-GPU commitment.

**Standing rule across all phases:** frontier APIs are never removed — they remain a routed backend for fallback, overflow, and quality-tier workloads.

---

## 12. Key decisions and open questions

**Decided (this document):**
- Inference layer is stateless and fully isolated from orchestration. (Core decision.)
- OpenAI wire protocol everywhere; vLLM as serving engine; LoRA-on-shared-base over per-model deployments.
- LiteLLM proxy (pinned, hardened) as initial gateway; single front door for all products.
- Langfuse (self-hosted) for prompt/template management and tracing; the custom app registry is reduced to agent config + governance glue (§6.4).
- Sessions/memory live in orchestration, keyed by product + tenant + session; never in gateway or inference.
- Incremental migration with frontier fallback as a permanent capability.

**Open — to be resolved during Phases 0–1:**
1. Base model selection (Arabic/English benchmark shortlist and evaluation owner).
2. EKS vs. ECS for GPU nodes (team operational preference).
3. Orchestration service stack (TypeScript to align with Kleem's worker vs. Python to align with Qams's AI service — or both, sharing only the gateway contract).
4. Whether Qams's quality tier ends up local-large, frontier-permanent, or hybrid — answered by Phase 3 benchmarks.
5. Guardrails/caching at the gateway: adopt when a concrete need appears, not speculatively.

---

## 13. Risks and mitigations

| Risk | Impact | Mitigation |
|---|---|---|
| Local model quality below frontier for a feature | User-visible regression | Per-feature eval gate before traffic shift; frontier remains routed |
| GPU cold start / capacity spike | Latency or errors | Warm minimum replicas; gateway TTFT-timeout failover to frontier |
| Gateway compromise (holds all credentials) | Severe | Version pinning, isolated subnet, Secrets Manager, egress lockdown, audit |
| Gateway as availability bottleneck | Platform-wide outage | ≥2 stateless replicas behind LB; Redis is the only shared state |
| Orchestration state coupling creep into gateway/inference | Loss of isolation, scaling pain | Design invariant enforced in review; layer contracts documented here |
| GPU spend exceeds frontier baseline | Negative ROI | Phase-gated rollout with cost dashboard as the scoreboard; Bedrock checkpoint before large-GPU commitments |
| Single engineer/bus-factor on platform ops | Operational fragility | Manifest/IaC-driven deploys; runbooks written during Phase 0–1 |

---

*End of document.*