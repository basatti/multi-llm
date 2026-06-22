# LLM Platform — Architecture & Implementation Plan

**Status:** Adopted — v1.1, review feedback folded in
**Date:** June 2026
**Scope:** Shared LLM serving platform for multiple applications on GPU infrastructure (AWS reference deployment included)

---

## Current implementation note (2026-06-13)

This doc describes the **target architecture**. The **current single-box deploy** (terraform/envs/sandbox, ~$155/mo with the cost-saving schedule) departs in two ways and the differences are deliberate:

1. **Inference engine: Ollama, not vLLM.** vLLM is the right tool for one pinned high-throughput model. The current shape is three small models (llama3.1, gemma4, qwen2.5-coder) sharing one 16 GB GPU via hot-swap — Ollama handles that natively. vLLM remains the future option for a dedicated high-throughput model when traffic justifies a second box (the §4.1 escape hatch).

2. **Gateway model names are real model names, not logical role-coupled aliases.** The doc references `realtime-chat`, `chat-default`, `quality-rag`, `summarize-cheap` throughout — those reflect the Phase 1+ design where logical names abstract the physical model. In the current deploy, application keys are scoped at the LiteLLM layer (via the admin UI) and the model field carries the literal model name (`llama3.1`, `gemma4`, `qwen2.5-coder`). When the platform grows back to multiple deployments per logical role, the logical names layer back on top.

Layer isolation, gateway-as-front-door, atomic manifest+route PRs, secrets policy, and the rollout phases all stand as written.

---

## 1. Executive summary

Organisations running multiple AI-using SaaS products commonly power them through direct frontier-model API integrations, with provider keys embedded per service. This works but does not scale organisationally or financially: every product re-implements model access, cost is opaque and unattributable, latency-critical features compete with batch workloads, and there is no path to self-hosted models for cost control, fine-tuning, or data residency.

This document defines a four-layer LLM platform: a **stateless GPU inference layer** running open-weight models on owned compute, fronted by a **gateway** that unifies routing, auth, budgets, and frontier-API fallback, with a separate **stateful orchestration layer** owning sessions, memory, RAG, and agent loops, consumed by the **application layer**.

The central architectural decision: **the inference layer is fully isolated from all stateful and agentic concerns.** Inference nodes receive messages and return tokens — nothing else. Sessions, memory, tool execution, and conversation state live exclusively in the orchestration layer. This isolation is what allows independent scaling, model lifecycle management without product changes, contained blast radius, and a single governance choke point.

Migration is incremental: existing frontier API usage is re-pointed at the gateway first (no behaviour change), then traffic shifts to local models feature-by-feature as quality and cost are validated.

---

## 2. Goals and non-goals

### Goals

1. **Single front door for all model access.** Every LLM call from every application and microservice flows through one gateway, regardless of whether it resolves to a local GPU or a frontier API.
2. **Self-hosted inference capability.** Run multiple open-weight models (and fine-tuned variants) on owned GPU compute with an OpenAI-compatible interface.
3. **Strict layer isolation.** Inference is stateless; orchestration is stateful; applications never talk to GPUs directly.
4. **Per-application cost attribution and budgets.** Answer "what did application X's AI features cost last month, local vs. frontier?" from gateway telemetry alone.
5. **Latency tiering.** Realtime paths get pinned warm capacity and hard TTFT targets; batch/async workloads use cheap spare capacity.
6. **Graceful degradation.** Local GPU failures, cold starts, or capacity spikes fall back to frontier APIs transparently; no application-visible outage.
7. **Incremental migration.** No big-bang cutover. Frontier APIs remain a first-class routed backend indefinitely.

### Non-goals

- Building a custom inference engine (we use vLLM).
- Building a custom gateway from scratch (we adopt and harden an existing one).
- A single shared "memory" abstraction forced across all applications — orchestration starts shared but is expected to specialise per application.
- Model training infrastructure. Fine-tuning pipelines are out of scope for this phase; the platform only needs to *serve* LoRA adapters produced elsewhere.

---

## 3. Architecture overview

Four layers, strictly ordered. Calls only flow downward. **Orchestration is mandatory for all stateful or agentic calls** (sessions, memory, RAG, tool loops). Applications may call the gateway directly **only for stateless one-shot completions** — that is the single sanctioned shortcut, and no layer ever reaches the inference layer except the gateway.

```
┌─────────────────────────────────────────────────────────┐
│  4. APPLICATION LAYER                                   │
│     SaaS apps · microservices · internal tools          │
└───────────────┬─────────────────────────┬───────────────┘
                │  agentic / stateful     │  one-shot
                ▼                         │  completions
┌───────────────────────────────┐         │  (stateless only)
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
│  vLLM / Ollama on GPU   │   │  Anthropic / OpenAI /     │
│  Stateless, OpenAI-     │   │  Bedrock — fallback,      │
│  compatible, multi-LoRA │   │  overflow, quality tier   │
└─────────────────────────┘   └───────────────────────────┘
```

### Layer responsibilities at a glance

| Layer | State | Knows about | Never knows about |
|---|---|---|---|
| Inference (LLM repo) | None | Messages in, tokens out, LoRA adapter IDs | Callers, sessions, tenants, tools |
| Gateway | Routing/limit counters only (Redis) | Virtual keys, budgets, logical→physical model map, backends | Conversations, memory, business logic |
| Orchestration | Sessions, memory, RAG indexes | Applications, tenants, tools, conversation history | Physical model deployments, GPU topology |
| Applications | Their own domain state | Their own features; logical model names | Which physical model served a request |

---

## 4. Layer 1 — Inference ("LLM repo")

### 4.1 Serving engine

- **Engine:** vLLM, exposing the OpenAI-compatible `/v1/chat/completions` (and `/v1/completions`) endpoints. SGLang is the evaluated alternative if vLLM hits a wall; the OpenAI wire contract makes the engine swappable.
- **Contract:** The inference layer is *dumb and stateless*. A request contains messages, sampling parameters, and optionally a LoRA adapter name. There is no database access, no session lookup, no tool execution, no retrieval. Tokens stream out; the slot is freed.
- **Streaming:** Server-sent events end to end. Every consumer upstream must pass tokens through rather than buffer-then-forward — this is a platform-wide invariant required by any realtime voice path.

### 4.2 Multi-model strategy: base models + LoRA, not one deployment per model

The dominant cost lever. Instead of one GPU deployment per application-specific model:

- Run a small number of **base models** (e.g., one strong multilingual 8–14B for general chat/summarisation, one larger model if a use case demands it).
- Application-specific fine-tunes are served as **hot-swappable LoRA adapters** on the shared base via vLLM's multi-LoRA serving. Dozens of logical "models" per GPU instead of one.
- Apply **quantization** (FP8 on Hopper/Ada-class GPUs, AWQ otherwise) to increase concurrency per card or fit larger bases.
- If your applications target a non-English market, bilingual or multilingual capability is a hard requirement for model selection; candidate bases must be benchmarked on the target languages before adoption. **The benchmark shortlist is a Phase 0 deliverable** (§11) — small open-weight models are historically weakest exactly where you need them, so this cannot trail the infrastructure work.

### 4.3 AWS instance strategy

| Workload | Model class | Instance family | Notes |
|---|---|---|---|
| Realtime voice turns | Small/fast 7–14B, quantized | `g6e` (L40S) or `g5` (A10G) | Pinned warm replicas, never scale-to-zero |
| General application features (chat / summarisation / drafting) | 7–34B | `g5` / `g6e` | Warm baseline of 1 replica per active model |
| Heavy RAG / long-context (inspection, regulatory, document review) | 34–70B+ | `p4d` (A100) / `p5` (H100) only if justified | Validate demand on frontier fallback first |
| Batch/async (summaries, analytics) | Smallest viable | Spare capacity on the above; Spot where tolerable | Queue-based, latency-insensitive |

**Embeddings are a separate serving problem.** They have a different profile (high-throughput, CPU-viable, latency-tolerant) and are deliberately *not* covered by the GPU strategy above. Open question (§12): gateway-routed managed embeddings (Bedrock/OpenAI) vs. self-hosted in the LLM repo. Either way they route through the gateway like everything else. Resolve by Phase 1, when the first RAG workload makes it concrete.

**Autoscaling rules:**
- Scale on **queue depth and TTFT**, not CPU/GPU utilization alone.
- Maintain a **warm minimum of one replica per actively routed model**. Cold starts cost tens of seconds to minutes (weight loading); they are absorbed by the gateway's frontier fallback, never by the user.
- Scale-to-zero is permitted only for low-traffic models on async paths.

**Economics checkpoint (applies to ALL GPU spend, not just large instances):** A warm g5/g6e replica costs on the order of $700–1,400/month before serving a single useful token. For modest traffic, frontier APIs with prompt caching are often cheaper than even one warm GPU. Therefore: **every warm-capacity commitment — including the first g5/g6e baseline — requires a break-even calculation from Phase 0 gateway telemetry** (token volume × frontier unit cost vs. warm-replica monthly cost). Before committing to large-GPU spend (`p4d`/`p5`), additionally re-evaluate AWS Bedrock's open-weight catalog. Self-hosting earns its keep with custom LoRAs, data-residency constraints, or sustained high volume; if a use case has none of those, Bedrock (routed through the same gateway) may be the cheaper operational answer.

### 4.4 Repository and deployment model

- **This repository (`llm-repo`) is the platform monorepo:** Terraform for the AWS reference, container definitions for vLLM/Ollama and the gateway, the model manifest (`models/manifest.yaml`) mapping model IDs → weights (S3) → LoRA adapters → instance class → replica policy, **and the gateway routing config** (`gateway/config/`). Co-locating manifest and routes makes a model change + route update a single atomic PR, enforced by CI (`scripts/validate_routes.py`). The orchestration service skeleton also lives here initially and can be extracted once it specialises per application.
- CI deploys model changes without touching orchestration or applications. Adding a model or adapter is a manifest change + gateway route update in one PR, zero application code changes.
- Model weights stored in S3 in-region; nodes pull on boot (or from a warm EBS/FSx cache to cut cold-start time).

---

## 5. Layer 2 — Gateway / router

### 5.1 Responsibilities

1. **Logical model routing.** Applications request logical names (`realtime-chat`, `chat-default`, `quality-rag`, `summarize-cheap`); the gateway maps these to physical backends. Re-pointing a logical name is a config change, invisible to applications.
2. **Auth via virtual keys.** Each application/service receives a gateway-issued virtual key. Real provider credentials (Anthropic, OpenAI, Bedrock IAM) live only in the gateway's secret store. Keys are scoped, budgeted, and revocable per application. **Tenant attribution is mandatory, not optional:** multi-tenant applications send `metadata.tenant_id` on every request; it is part of the gateway logging schema from day one, and requests missing the tag on tenant-scoped routes are flagged (later: rejected). Per-tenant *keys* remain available where stronger isolation is warranted.
3. **Rate limits and budgets.** Request/token/spend caps per virtual key. A runaway agent loop in one application cannot exhaust GPU capacity or frontier spend for the others.
4. **Fallback chains, retries, load balancing.** Per logical name: ordered backend list with timeout and error policies. Example: `realtime-chat` → local vLLM (TTFT timeout 400 ms) → fast frontier model. **For latency-critical routes, hedged requests are the evaluated alternative** (§7.1): race local against a fast frontier model and cancel the loser at first token, trading a few duplicate tokens for the elimination of additive failover latency.
5. **Model lifecycle: enable/disable.** Enabling or disabling a model is a gateway routing change, not a deployment event. Soft disable: remove the physical backend from the logical name's route — new requests immediately resolve to the next backend in the fallback chain, in-flight streams complete, applications see nothing (they only know logical names). Hard disable: after draining, scale the vLLM deployment to zero via the `llm-repo` manifest to release GPU spend. Per-app revocation is handled by key scoping. Two enforced rules: every logical name backed by a local model must have a fallback chain (a disabled model with no fallback is an outage — CI-enforced by `scripts/validate_routes.py`), and disable ≠ delete — manifests and weights are retained so re-enable is a config flip plus warm-up.
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

**Latency escape hatch:** If gateway overhead on a realtime voice path proves measurable against the TTFT budget, evaluate a faster Go-based gateway (e.g., Bifrost) *for that path only*, keeping LiteLLM for everything else. Decide from measured TTFT data, not preemptively.

### 5.3 Design invariant

The gateway is **stateless and conversation-blind**. It knows keys, budgets, routes, and backends. The moment session or memory logic appears in the gateway, the isolation this architecture exists to protect has been broken.

---

## 6. Layer 3 — Orchestration (stateful)

### 6.1 Responsibilities

- **Session state:** conversation history keyed by `application + tenant + session_id`, held server-side.
- **Memory:** short-term (session window management, summarisation-on-overflow) and long-term (per-tenant/user persistent memory) as applications require it.
- **RAG:** retrieval pipelines over application corpora (e.g., regulatory documents, internal knowledge bases) with provenance tracking.
- **Tool calling and agent loops:** executing tools, feeding results back, managing multi-step plans — all the slow, I/O-bound work that must never sit on a GPU node.
- **Prompt assembly:** system prompts, retrieved context, memory, and history are composed here; applications send intents and payloads, not raw prompts, for agentic features.

### 6.2 Structure

- **Start as one shared orchestration service** (with clean per-application modules) to avoid re-building session plumbing for each new application. **Stack: Python/FastAPI** (decided — aligns with the Python LLM ecosystem; non-Python applications consume it over HTTP/SSE).
- **Expect and plan for per-application specialisation.** A voice-turn loop (barge-in, sub-second budgets, TTS coupling) and a RAG inspection pipeline (long documents, provenance, locked rubrics) will diverge over time. The shared core should be session storage, memory primitives, and the gateway client; the loops on top are application-owned.
- All model calls from orchestration go **through the gateway** using orchestration's (or the originating application's) virtual key — orchestration never holds provider credentials and never addresses the inference backend directly.

### 6.3 State storage

- Session/conversation state: Redis (hot) + a durable store (PostgreSQL or MongoDB, aligned with each application's existing stack) for recovery and audit.
- Vector retrieval: per-application choice (Atlas Vector Search, pgvector, OpenSearch, etc.); orchestration treats retrieval backends as pluggable.

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

## 7. Layer 4 — Application integration patterns

### 7.1 Realtime voice agent — two distinct paths

**Realtime path (the voice loop):**
- A worker process holds a streaming connection to orchestration per active call, keyed by `session_id`. The worker keeps no conversation state locally — orchestration owns it — so workers scale horizontally and dropped connections recover cleanly.
- Orchestration manages the turn: history, memory, tool calls, prompt assembly, then streams the completion from the gateway.
- **Hard TTFT budget (target ≤ 400 ms to first token at the gateway).** Routed to a pinned, warm, quantized small model. On TTFT timeout, the gateway fails over to a fast frontier model — a slightly costlier fast answer always beats a cheap slow one in voice.
- **Failover strategy is an open measurement question.** Sequential failover makes the user pay the 400 ms timeout *plus* frontier TTFT on every miss. The alternative is **hedged requests**: fire local and fast-frontier together, stream from whichever produces a token first, cancel the other. Costs a few duplicate tokens per turn; removes additive tail latency entirely. Decide from Phase 2 shadow-traffic TTFT data, not preemptively.
- **Streaming is end-to-end:** GPU → gateway → orchestration → worker → TTS, with TTS fed at sentence/clause boundaries so audio begins while generation continues.
- **Cancellation propagates.** On barge-in, the worker closes the stream; orchestration and gateway propagate the abort so the inference backend frees the sequence immediately. Interrupted turns must not keep burning GPU.

**Async path (post-call work):**
- Summaries, transcript analysis, intent extraction, quality scoring: queued jobs straight to the gateway as one-shot completions on the cheapest suitable model. No session, no orchestration, no latency constraint. These must never share the pinned realtime capacity.

### 7.2 Business / drafting applications

- Predominantly request/response features (drafting, summarisation, classification): direct gateway calls with logical names on the standard tier.
- Any future conversational/assistant feature goes through orchestration like the others.

### 7.3 RAG-heavy applications (regulatory review, inspection, document analysis)

- The RAG pipeline (version-pinned retrieval, locked rubric, provenance stamping) lives in orchestration (or in a dedicated microservice that calls the gateway instead of providers directly — acceptable interim state).
- Routed to a quality-tier logical model (`quality-rag`), which may resolve to a larger local model or a frontier model depending on validated accuracy; accuracy outranks cost here.
- Async inspection jobs use the batch tier.

### 7.4 General microservices

Any microservice needing AI gets a virtual key and calls the gateway with a logical model name — **stateless one-shot completions only**; anything needing sessions, memory, or tools goes through orchestration (§3). No application service ever receives provider API keys again.

---

## 8. Network and deployment topology (AWS)

- **Single VPC (per environment), three tiers of subnets:**
  - *Application subnets* — existing services.
  - *Platform subnet* — gateway replicas + orchestration service + Redis/ElastiCache, behind internal load balancers.
  - *GPU subnet* — vLLM nodes, isolated; ingress only from the gateway security group; egress only to S3 (weights) and telemetry.
- **No public ingress to gateway or GPU nodes by default.** Applications reach the gateway over internal DNS (e.g., `llm-gateway.internal.example.com`).
- **Compute:** GPU nodes on EKS with the NVIDIA device plugin (preferred, aligns with manifest-driven deploys and autoscaling via Karpenter), or ECS/ASG if the team prefers lower Kubernetes overhead initially. Tracked as ADR 0001; the gateway itself runs on ECS Fargate either way.
- **Secrets:** AWS Secrets Manager for provider credentials and the gateway's master key; IAM roles for service-to-service auth where applicable.
- **Environments:** `dev` (CPU or single small GPU + frontier-heavy routing), `staging`, `prod`. Routing tables are per-environment config.

---

## 9. Observability and cost model

All telemetry hangs off the gateway because every request crosses it.

**Per-request fields:** virtual key (application/service), `tenant_id` (mandatory request metadata on tenant-scoped routes), logical model, resolved backend, prompt/completion tokens, TTFT, total latency, status, fallback-triggered flag, computed cost.

**Dashboards (minimum):**
1. Cost per application per day, split local vs. frontier — the migration scoreboard.
2. TTFT p50/p95/p99 per logical model — the realtime SLO view.
3. GPU utilization vs. queue depth per deployment — scaling signal.
4. Fallback rate per logical name — local capacity/health signal; a rising fallback rate is the earliest warning that GPU capacity or health is degrading.
5. Error and retry rates per backend.

**Quality signal:** sampled completions per feature routed into a lightweight eval loop (even manual review initially) before any feature's traffic shifts from frontier to local. Cost data without quality data leads to false savings.

---

## 10. Security and governance summary

- Real provider credentials exist **only** in the gateway's secret store. Applications and orchestration hold revocable virtual keys.
- Per-key budgets and rate limits enforce blast-radius containment by default.
- GPU subnet accepts traffic only from the gateway; the inference layer is unreachable from applications even by mistake.
- Gateway software supply chain: version pinning, artifact verification, dependency review on every upgrade (lesson of the March 2026 LiteLLM incident).
- Data residency: self-hosted models keep prompts/completions in-region in your VPC; routing policy can pin sensitive logical names (e.g., regulated workloads) to **local-only** backends with no frontier fallback. This must be an explicit per-route flag.
- Audit: gateway request logs retained per compliance requirements (align retention with the data-protection obligations applicable in your jurisdiction; prefer logging metadata over full prompt bodies for sensitive routes).

---

## 11. Rollout plan

**Phase 0 — Gateway in front of what exists (1–2 weeks)**
Deploy hardened LiteLLM proxy (2 replicas + Redis). Issue virtual keys to every application and microservice that calls LLMs today. Re-point all existing frontier API calls at the gateway with logical names. *No model changes.* Outcome: unified telemetry, budgets, and the cost baseline.
**Parallel Phase 0 deliverable: the base-model benchmark.** Shortlist candidates against your target languages and tasks, name an evaluation owner, run the eval. This gates Phase 1 — infrastructure must not be ready before you know what to put on it.

**Phase 1 — First local model on the async tier (2–4 weeks)**
**Entry gate (go/no-go):** break-even calculation from Phase 0 telemetry — measured token volume × frontier unit cost (including prompt caching) vs. warm g5/g6e replica monthly cost. If the math doesn't clear, Phase 1 waits or the workload goes to Bedrock through the same gateway; no GPU spend on faith.
Stand up the inference layer: one vLLM deployment, the benchmark-selected quantized 8–14B base, on `g5`/`g6e`. Route low-risk async workloads (post-call summaries, drafting, summarisation) to it with frontier fallback. Deploy self-hosted Langfuse and stand up the minimal app registry (§6.4): app profiles, owner/cost-center metadata, first versioned prompt templates in Langfuse. Validate quality via sampled evals; validate cost via dashboard 1.

**Phase 2 — Realtime voice path (3–5 weeks, overlaps Phase 1)**
Stand up orchestration's session service for voice turns (server-side state, streaming, cancellation). Pin warm replicas for `realtime-chat`, enforce the 400 ms TTFT budget with frontier failover. Shift live traffic gradually (shadow → percentage rollout), watching TTFT p95/p99 and fallback rate. Use shadow-traffic data to decide sequential failover vs. hedged requests (§7.1).

**Phase 3 — RAG-heavy workloads**
Refactor RAG/inspection services to call the gateway. Benchmark local candidates against the frontier baseline on accuracy (rubric adherence, provenance fidelity) before shifting any traffic. Accuracy gates the migration; cost does not.

**Phase 4 — LoRA serving and specialisation**
Introduce multi-LoRA serving for the first application fine-tune. Split orchestration per application where the shared loops have visibly diverged. Re-run the Bedrock checkpoint before any large-GPU commitment.

**Standing rule across all phases:** frontier APIs are never removed — they remain a routed backend for fallback, overflow, and quality-tier workloads.

---

## 12. Key decisions and open questions

**Decided:**
- Inference layer is stateless and fully isolated from orchestration. (Core decision.)
- OpenAI wire protocol everywhere; vLLM as serving engine; LoRA-on-shared-base over per-model deployments.
- LiteLLM proxy (pinned, hardened) as initial gateway; single front door for all applications. Gateway runs on ECS Fargate in the AWS reference. **Config-only engagement: no forking, no custom gateway code in Phases 0–2.**
- **Langfuse (self-hosted) for prompt/template management and tracing;** the custom app registry is reduced to agent config + governance glue (§6.4).
- Sessions/memory live in orchestration, keyed by application + tenant + session; never in gateway or inference.
- **Orchestration stack: Python/FastAPI**, one shared service initially, application-owned loops on top.
- **`llm-repo` is the platform monorepo:** inference IaC + model manifest + gateway config (+ orchestration skeleton initially); manifest/route changes are atomic PRs enforced by CI.
- **Tenant attribution via mandatory `metadata.tenant_id`** request tag on tenant-scoped routes, in the logging schema from day one.
- Incremental migration with frontier fallback as a permanent capability; **every warm-GPU commitment passes a telemetry-based break-even gate first.**

**Open — to be resolved during Phases 0–1:**
1. Base model selection — benchmark shortlist and evaluation owner for your target languages and tasks. **Phase 0 deliverable; gates Phase 1 start.**
2. EKS vs. ECS for GPU nodes (team operational preference) — ADR 0001; decide before Phase 1 implementation of the inference module.
3. **Embeddings serving:** gateway-routed managed embeddings (Bedrock/OpenAI) vs. self-hosted in the LLM repo. Different serving profile from chat models (CPU-viable, throughput-oriented). Routed through the gateway either way; resolve by Phase 1 alongside the first RAG workload.
4. Whether the quality tier (`quality-rag`) ends up local-large, frontier-permanent, or hybrid — answered by Phase 3 benchmarks.
5. Realtime failover: sequential TTFT-timeout vs. hedged requests — answered by Phase 2 shadow-traffic data.
6. Guardrails/caching at the gateway: adopt when a concrete need appears, not speculatively.

---

## 13. Risks and mitigations

| Risk | Impact | Mitigation |
|---|---|---|
| Local model quality below frontier for a feature | User-visible regression | Per-feature eval gate before traffic shift; frontier remains routed |
| GPU cold start / capacity spike | Latency or errors | Warm minimum replicas; gateway TTFT-timeout failover (or hedging) to frontier |
| Gateway compromise (holds all credentials) | Severe | Version pinning, isolated subnet, Secrets Manager, egress lockdown, audit |
| Gateway as availability bottleneck | Platform-wide outage | ≥2 stateless replicas behind LB; Redis is the only shared state |
| Orchestration state coupling creep into gateway/inference | Loss of isolation, scaling pain | Design invariant enforced in review; layer contracts documented here |
| GPU spend exceeds frontier baseline | Negative ROI | Break-even gate from Phase 0 telemetry before ANY warm-GPU commitment; Bedrock checkpoint before large-GPU commitments; cost dashboard as the scoreboard |
| Target-language quality gap in small open models | Phase 1 stalls or ships poor UX | Benchmark shortlist resolved during Phase 0; eval gates traffic shift; frontier stays routed |
| Single engineer/bus-factor on platform ops | Operational fragility | Manifest/IaC-driven deploys; runbooks written during Phase 0–1 |

---

*End of document.*
