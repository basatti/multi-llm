# PMS ↔ LLM Platform integration

Survey + integration plan for connecting **PMS** (the 1TechHub property/sales/help-desk platform) to **`https://llm.kleem.io`**.

---

## TL;DR

PMS is **already AI-enabled** end-to-end. The backend (NestJS at `pms/apps/api`) has an `AiAssistant` module with multi-provider support (OpenAI / Gemini / Bytez), per-workspace settings, BullMQ async, Socket.IO realtime, and scope-aware data isolation. The frontend (Vite/React at `pms/apps/web`) has matching UI: a Settings → AI page, draft-tasks/draft-deals modals, and a report-builder NL-to-query panel.

**Integration is two env vars.** LiteLLM speaks the OpenAI wire protocol. Set the OpenAI provider's `baseURL` to our gateway and `OPENAI_API_KEY` to the PMS virtual key — every existing AI route in PMS works against our self-hosted models with no other code changes.

---

## Current state (as of 2026-06-14, pms main @ 790fad48)

### Backend (`pms/apps/api`) — NestJS 11 + TypeORM + PostgreSQL

| Concern | Status |
|---|---|
| AI module | ✅ `src/modules/ai-assistant/` — fully built |
| Provider abstraction | ✅ `providers/ai-llm.client.ts` — OpenAI / Gemini / Bytez |
| Per-workspace settings | ✅ `ai-settings.repository.ts` + `ai-runtime-config.service.ts` (env defaults, DB overrides) |
| Async queue | ✅ BullMQ `@InjectQueue('ai')` |
| Realtime push | ✅ Socket.IO gateway already wired |
| Scope isolation | ✅ `AiAssistantScopeContext` respects `Scope` + `allowedScopeIds` |
| Bilingual | ✅ i18n at `apps/web/locales/{en,ar}/pages/aiSettings.json` |

Existing endpoints under `/api/v1/ai/`:

| Route | Job |
|---|---|
| `POST draft-tasks` | Generate Tasks from a prompt + optional project/deal context |
| `POST draft-deals` | Generate Deals (resolves org/contact names against the DB) |
| `POST summarize-report` | Turn a report payload into a business-insights summary |
| `POST suggest-query` | NL → report builder filters |
| `POST activity-insights` | Q&A over ActivityLog with citations |
| `GET / PATCH settings` | Per-workspace config; `ai-settings:update` permission |

### Frontend (`pms/apps/web`) — React 18 + Vite + Zustand + i18next

| Surface | Where |
|---|---|
| AI settings panel | `/settings/ai-settings` (`AiSettingsTab.tsx`) — provider/model/keys + test-connection |
| Task drafting modal | `AiDraftTasksModal.tsx` |
| Deal drafting modal | `AiDraftDealsModal.tsx` |
| Report-builder AI panel | `ReportBuilderPage.tsx` (`suggestQuery`, `summarizeReport`) |
| Store | `src/store/ai-assistant.store.ts` |
| Permissions | `ai-tasks:use`, `ai-deals:use`, `ai-reports:use`, `ai-dashboard:use`, `ai-kpi:use`, `ai-insights:use`, plus blanket `ai:use` |

**Verdict: ready to integrate.** No new infra, no new module, no new UI required for the first wave.

---

## Integration: simplest possible (recommended)

The PMS `AiAssistant` already supports OpenAI. LiteLLM at `https://llm.kleem.io` is OpenAI-wire-compatible. Therefore:

### Step 1 — Fetch the PMS virtual key

```bash
aws ssm get-parameter --region ap-south-1 \
  --name /llm-platform/prod/apps/pms/api_key \
  --with-decryption --query Parameter.Value --output text
```

### Step 2 — Wire env (or use the UI)

In `pms/apps/api/.env`:

```env
AI_PROVIDER=openai
OPENAI_API_KEY=<the SSM value above>
OPENAI_BASE_URL=https://llm.kleem.io/v1
AI_OPENAI_MODEL=gemma4
AI_MAX_TOKENS=4096
```

If the existing `ai-llm.client.ts` reads `OPENAI_API_KEY` but not `OPENAI_BASE_URL`, a one-line patch is needed there (or use the per-workspace DB override via `/settings/ai-settings`, which the codebase already supports).

> Currently `pms` defaults to model `gpt-4o-mini`. Swap to `gemma4` (PMS is scoped to that model on the gateway). To use a different model, re-scope the key in **https://litellm.kleem.io/ui/** → no PMS redeploy.

### Step 3 — Smoke test through PMS itself

1. PMS admin → Settings → AI Assistant → "Test connection". Expect green.
2. Open any deal → AI Draft Tasks. Type `"Schedule a follow-up call with Acme Co for next Tuesday and draft a discovery agenda"` → expect 1-3 task drafts.
3. Reports → AI assistant → `"Deals closed last quarter by stage"` → expect filters auto-populated.

That's it — every existing AI feature in PMS now runs on **our** GPU, with **our** budgets, **our** tenant attribution, and **our** Langfuse traces.

---

## What changes vs the current OpenAI/Gemini setup

| | Before (OpenAI / Gemini direct) | After (via llm.kleem.io) |
|---|---|---|
| Where prompts/data go | OpenAI servers (US) / Google | Our VPC in `ap-south-1` (Mumbai) |
| Cost attribution per tenant | manual / impossible | automatic in Langfuse (`metadata.tenant_id`) |
| Per-tenant budgets | not enforced | enforceable per virtual key in LiteLLM |
| Key rotation | one global env var change | LiteLLM UI, no PMS restart |
| Model swap | code/env change | LiteLLM UI re-scope |
| Audit log | none | every request in Langfuse |
| Cost | per-token to OpenAI | own GPU (fixed ~$155/mo for the box) |

**Important:** PMS should send `metadata.tenant_id` on every gateway request. The `ai-llm.client.ts` currently doesn't pass metadata — that's a small additive change (~10 lines) so per-tenant cost dashboards work. Until that lands, all PMS calls attribute to "no tenant" in Langfuse but still attribute correctly to the PMS key.

---

## Use cases — what to wire (and in what order)

The reports above surfaced ~20 surfaces. Here's the ranking by **impact × low-effort**, with concrete landing spots.

### Tier 1 — ship this week (zero new endpoints)

These run on the existing `/api/v1/ai/draft-tasks`, `draft-deals`, `summarize-report`, `suggest-query`, `activity-insights` routes. Once env is flipped to our gateway, they work — the UI is already there.

1. **AI Draft Tasks from deal/visit notes** — `AiDraftTasksModal` already exists; users paste freeform notes after a customer call and get 1-N draft tasks.
2. **AI Draft Deals from inbound emails / forms** — `AiDraftDealsModal`; org/contact name resolution against the DB is already there.
3. **Report-builder NL→filters** — typing `"Visits done last month in Mumbai by Junior agents"` populates filters.
4. **Report summarization** — one click on any built report.
5. **Activity Q&A** — `/api/v1/ai/activity-insights` already returns answers with citations.

### Tier 2 — small additive features (one new endpoint each, UI hook into existing forms)

Each is ~150–300 lines of NestJS + a button in an existing detail page.

6. **Quotation intro + T&C auto-draft** — `Quotation.introduction` and `Quotation.termsConditions` are free-text fields. New `POST /quotations/:id/ai/draft-intro` reads deal context + `CompanySettings.defaultIntroduction` and returns proposed text. UI: "Generate intro" button next to the field. *Why first: salespeople retype the same boilerplate every quote.*
7. **Help-desk request triage** — `POST /help-desk/:id/ai/triage` reads `HelpDeskRequest.description` and returns suggested priority + category + suggested workflow stage. UI: badge next to the request in the queue, click to accept. *Why: HelpDesk has a queue; this cuts triage time per ticket from minutes to seconds.*
8. **Help-desk reply drafting** — `POST /help-desk/:id/ai/draft-reply` reads the thread + KB entries (`HelpDeskKb`) and returns a suggested reply. UI: "Draft reply" button in the agent reply composer.
9. **Contact / Organization description polish** — small in-place "✨ Polish" button on the description fields. One call, returns a tighter version of the text the user just typed.
10. **Visit report summarization** — when a sales rep checks out of a visit and writes a long form-filled report, generate a 3-bullet summary for the deal timeline.

### Tier 3 — bigger surface (new modules / vector index)

11. **Semantic search across comments + activity** — replace keyword search on `/contacts`, `/deals`, `/tasks` with NL queries (`"contacts who mentioned pricing concerns last quarter"`). Needs an embeddings layer — the gateway can route to a managed embeddings endpoint, no GPU work locally. Real value, but more plumbing.
12. **Contract clause extraction** — `Contract.htmlSnapshot` → structured fields (payment terms, termination, renewal). Useful when contracts come back signed.
13. **Anomaly detection on payments** — surface unusual patterns in `Sale.paymentHistory` via the existing report engine.
14. **Lease clause Q&A** — ask natural questions about a specific contract.
15. **Auto-tag contacts/deals** — given a description and the existing tag corpus, propose tags.

---

## Suggested rollout

| Week | Work | Outcome |
|---|---|---|
| 1 | Patch `ai-llm.client.ts` to read `OPENAI_BASE_URL` env var. Add `metadata.tenant_id` passthrough on every call. Flip PMS staging env to llm.kleem.io. Smoke all 5 existing AI routes. | Existing AI features running on our gateway |
| 2 | Ship Tier 2 #6 (quotation drafting) + #7 (help-desk triage) — both are self-contained endpoints + a button | Two new visible features |
| 3 | Ship Tier 2 #8, #9, #10 (reply drafting, polish, visit summary) | All the high-frequency authoring touchpoints assisted |
| 4+ | Begin Tier 3 #11 (semantic search) once budgets/traces show usage justifies the effort | Selectively, based on data |

---

## Open questions

1. **Model per use case?** Right now PMS is scoped to `gemma4` (one model for everything). Some use cases benefit from `qwen2.5-coder` (extraction, structured output) or `llama3.1` (low-latency interactive replies). Two options:
   - Keep one-model-per-app and accept gemma4 for everything (simple, today).
   - Broaden PMS's key scope at LiteLLM to all three; PMS chooses per route. Slightly more code, much more flexibility.
2. **Embeddings backend.** Tier 3 needs them. We have two paths (see architecture.md §4.3 open question): self-hosted on the same Ollama, or gateway-routed to managed (Bedrock/OpenAI embeddings). Decide before Tier 3.
3. **Cost-saving schedule.** PMS users may hit 504s after 22:00 IST (instance auto-stops). For real-app usage, either narrow the off-window or accept that nightly background AI jobs need to run before 22:00.
4. **Existing AI permissions.** The `ai-*:use` permission set is already enforced. New Tier 2 features should slot into the same model (add e.g. `ai-quotations:use`, `ai-helpdesk:use`).

---

## File pointers

- PMS AI module: `pms/apps/api/src/modules/ai-assistant/`
- Provider adapter (where the base-URL patch lands): `providers/ai-llm.client.ts`
- Settings (env + DB override): `ai-runtime-config.service.ts`, `ai-settings.repository.ts`
- Frontend store: `pms/apps/web/src/store/ai-assistant.store.ts`
- Frontend settings UI: `pms/apps/web/src/pages/settings/AiSettingsTab.tsx`
- Existing modals: `AiDraftTasksModal.tsx`, `AiDraftDealsModal.tsx`
- Report-builder AI panel: `pms/apps/web/src/pages/reports/ReportBuilderPage.tsx` (lines ~619–655)
