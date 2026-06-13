# PMS Tier 2 AI features — design

Concrete designs for the two highest-ROI Tier 2 endpoints from
[`pms-integration.md`](pms-integration.md): **quotation drafting** and
**help-desk triage**. This doc is what a PMS developer (or future agent)
implements from — every decision is named, every file path is concrete,
no guesswork.

Prereqs from Tier 1 are done (commits on `pms` branch
`feat/llm-platform-integration`): `OPENAI_BASE_URL` override, `tenant_id` /
`feature` metadata passthrough, broadened PMS key scope at LiteLLM
(`llama3.1` + `gemma4` + `qwen2.5-coder`).

---

## Architectural decisions (apply to both endpoints)

### 1. Endpoints live in `AiAssistantModule`, not the domain modules

The existing AI surface is `/api/v1/ai/*` and groups every AI feature
(drafts/tasks, drafts/deals, reports/*, dashboard/*, kpis/*). Tier 2
endpoints follow that pattern: `/api/v1/ai/quotations/:id/draft-intro`,
`/api/v1/ai/help-desk/:id/triage`. Three reasons:

1. Permission convention is already `ai-<feature>:use` (e.g. `ai-tasks:use`,
   `ai-reports:use`). The new endpoints get `ai-quotations:use` and
   `ai-helpdesk:use` — same shape, same admin UI.
2. AI dependencies (BullMQ queue, AiLlmClient, AiRuntimeConfigService,
   ActivityInsightsRateLimitGuard) are all already wired in
   `AiAssistantModule`.
3. Domain modules (Quotation, HelpDesk) stay pure — no AI logic creeps in.

`AiAssistantModule` will import `QuotationModule`, `CompanySettingsModule`,
`HelpDeskRequestModule`, `DealModule`. Verified no circular dep — none of
those import AI.

### 2. Prompts live in **Langfuse**, not hardcoded

CLAUDE.md §6.4 / architecture.md §6.4 makes Langfuse the prompt-management
layer. Three benefits over hardcoded prompts in PMS:

- Non-engineers can iterate on phrasing in the Langfuse UI
  (`https://langfuse.kleem.io`) without a PMS deploy.
- Versioning + labels (`development` / `production`) enable instant rollback
  and staged promotion.
- Trace linking: every gateway call records which prompt version produced
  what output, which means we can A/B-test new versions.

**The catch:** Tier 1 prompts (`TASK_SYSTEM`, `DEAL_SYSTEM`, etc.) are
currently inline constants in `ai-assistant.service.ts`. Moving them to
Langfuse is a larger refactor (touches all 9 callers) and out of scope for
Tier 2. So the pragmatic shape:

- **New** Tier 2 endpoints: fetch prompts from Langfuse from day one.
- **Existing** Tier 1 prompts: stay inline; migrate in a follow-up PR.

For Tier 2 we need a thin Langfuse client (no SDK required — same `fetch`
pattern `AiLlmClient` uses). See section "Langfuse client" below.

### 3. Per-feature model selection via `LlmCallOptions.model`

PMS's `AiLlmClient.completeJson()` currently always uses `c.openaiModel`
(`gemma4` for PMS). Tier 2 endpoints need to override per route:

| Endpoint | Best model | Why |
|---|---|---|
| Quotation drafting | `gemma4` | Generative writing, longer prose |
| Help-desk triage | `qwen2.5-coder` | Structured extraction, JSON-shaped output |

One-line patch to `LlmCallOptions` interface + `completeJsonOpenAI`:

```ts
// providers/ai-llm.client.ts
export interface LlmCallOptions {
  tenantId?: string;
  feature?: string;
  model?: string;       // ← new: override the default
}

// in completeJsonOpenAI:
const model = opts?.model ?? c.openaiModel;
```

### 4. Endpoints return drafts; they do NOT mutate

Mirrors the existing `draftTasks` / `draftDeals` pattern. The UI shows the
suggested text and the user accepts (which then triggers the existing
quotation `PATCH` route). Reasons:

- One-way LLM autopilot is dangerous; surface the suggestion first.
- Decouples AI quality from data integrity — bad draft = no-op, not bad row.
- Keeps the AI endpoint stateless; no need for new ActivityLog entries.

### 5. Async vs sync

`draftTasks` and `draftDeals` are **sync** (return the draft in the response
body, ~2-15 s round-trip). Tier 2 endpoints match — quotation drafting and
triage are both interactive operations a user is waiting on. Don't queue
them via BullMQ.

(The queue exists for batch jobs like "summarize all visit reports for last
quarter" — different shape, not Tier 2.)

---

## Endpoint 1 — Quotation intro + T&C drafting

### Contract

```
POST /api/v1/ai/quotations/:id/draft-intro
Headers:
  Authorization: Bearer <jwt or api-key>
Body: {} | { overwriteExisting?: boolean }
Response 200: {
  introduction: string,            // suggested intro paragraph
  termsConditions: string,         // suggested T&C block
  warnings: string[],              // empty unless context was insufficient
  usedTemplate: { name: string, version: number },  // Langfuse audit trail
}
Errors:
  401 — missing auth / out-of-scope key
  403 — `ai-quotations:use` permission missing
  404 — quotation not found / not in user's allowedScopeIds
  503 — AI provider unreachable / rate-limited
```

### Service flow

`AiAssistantService.draftQuotationIntro(quotationId, scope, options)`:

1. **Read quotation** via `IQuotationService.findOne(quotationId, scope.allowedScopeIds)`
   — already scope-aware (404 on out-of-scope).
2. **Read context entities** (in parallel where possible):
   - `quotation.deal` (already joined): `name`, `description`, `expectedValue`, `stage`
   - `quotation.deal.organization`: `name`, `industry`, `country`
   - `quotation.items`: array of `{description, quantity, unitPrice, currency}`
   - `companySettings.defaultIntroduction`, `defaultTermsConditions` (style reference)
3. **Build the variables map** for the prompt template:
   ```ts
   const vars = {
     deal_name: deal.name ?? '(unnamed deal)',
     deal_description: deal.description ?? '',
     org_name: org?.name ?? '(no organization)',
     org_industry: org?.industry ?? '',
     items_block: items.map(i => `- ${i.description} (qty ${i.quantity})`).join('\n'),
     default_intro: cs.defaultIntroduction ?? '',
     default_terms: cs.defaultTermsConditions ?? '',
     locale: req.user.locale ?? 'en',   // bilingual: en | ar
   };
   ```
4. **Fetch + compile prompt** from Langfuse: `pms/quotation-intro` (label
   `production`). Compile mustache-style placeholders.
5. **Call gateway** via `AiLlmClient.completeJson(system, user, opts)` with
   `model: 'gemma4'`, `tenantId: workspaceId`, `feature: 'quotation-drafting'`.
6. **Validate JSON shape**: `{introduction: string, termsConditions: string, warnings?: string[]}`.
   Reject empty `introduction` / `termsConditions` with `BadRequestException`.
7. **Return** without persisting. UI uses the value in a `PATCH /quotations/:id`
   call when the user accepts.

### Files to add / modify

| File | Change |
|---|---|
| `apps/api/src/modules/ai-assistant/dto/draft-quotation-intro.dto.ts` | New: `class DraftQuotationIntroDto { @IsOptional() @IsBoolean() overwriteExisting?: boolean; }` |
| `apps/api/src/modules/ai-assistant/interfaces/quotation-intro.types.ts` | New: `DraftQuotationIntroResponse` type |
| `apps/api/src/modules/ai-assistant/ai-assistant.service.ts` | Add `draftQuotationIntro()` method; reuse existing `normalizeAssistantJsonOutput` pattern; ~80 lines |
| `apps/api/src/modules/ai-assistant/ai-assistant.controller.ts` | Add `@Post('quotations/:id/draft-intro')` with `@CheckPermissions('ai-quotations:use')` |
| `apps/api/src/modules/ai-assistant/ai-assistant.module.ts` | Add `QuotationModule`, `CompanySettingsModule` to `imports[]` |
| `apps/api/src/modules/ai-assistant/providers/langfuse.client.ts` | New: thin client (see below) |
| `apps/api/src/modules/ai-assistant/providers/ai-llm.client.ts` | Add `model?: string` to `LlmCallOptions`; use it in `completeJsonOpenAI` |
| `apps/api/src/modules/ai-assistant/ai-runtime-config.service.ts` | Add `langfuseHost`, `langfusePublicKey`, `langfuseSecretKey` to `EffectiveAiRuntimeConfig` |
| `apps/api/.env.example` | Document Langfuse env block |
| Permission seed | Add `ai-quotations:use` permission key |

### Langfuse-hosted prompt (create via UI)

In Langfuse → Prompts → New prompt:

- **Name:** `pms/quotation-intro`
- **Type:** text
- **Labels:** `production`
- **Content:**

  > **System:** You are a senior B2B sales-proposal writer at 1TechHub.
  > Output a JSON object with two fields and nothing else: `introduction`
  > (3-5 sentence paragraph addressing the customer by name and framing the
  > deal context) and `termsConditions` (concise terms block: payment terms,
  > validity period, deliverables scope, jurisdiction). If `locale` is `ar`,
  > respond entirely in Modern Standard Arabic. Match the tone and clause
  > structure of the provided defaults; do not invent terms not implied by
  > the items.
  >
  > **User:** Deal: `{{deal_name}}`. Description: `{{deal_description}}`.
  > Organization: `{{org_name}}` ({{org_industry}}).
  >
  > Items:
  > `{{items_block}}`
  >
  > Default introduction style:
  > ```
  > {{default_intro}}
  > ```
  > Default terms style:
  > ```
  > {{default_terms}}
  > ```
  > Locale: `{{locale}}`. Return JSON only.

---

## Endpoint 2 — Help-desk triage

### Contract

```
POST /api/v1/ai/help-desk/:id/triage
Body: {}
Response 200: {
  suggestedPriority: 'low' | 'normal' | 'high' | 'urgent',
  suggestedCategoryId: string | null,
  suggestedWorkflowStageId: string | null,
  reasoning: string,                    // 1-2 sentences for the agent
  confidence: number,                   // 0-1, model self-reported
  warnings: string[],
}
```

### Service flow

`AiAssistantService.triageHelpDeskRequest(requestId, scope)`:

1. **Read the request** via `IHelpDeskRequestService.findOne(requestId, scope.allowedScopeIds)`.
2. **Read taxonomy**:
   - All `Category` entities visible to the scope (id, name, description) — for the model to choose from.
   - All `WorkflowStage` entities on the request's `RequestType.workflowDefinition` — only valid next stages from current.
   - Recent comments (last 5) on this request for additional context.
3. **Build variables** and fetch `pms/helpdesk-triage` from Langfuse.
4. **Call gateway** with `model: 'qwen2.5-coder'` (better at structured
   classification than gemma).
5. **Validate JSON**: enums for priority match the schema, IDs exist in the
   taxonomy lists (reject hallucinated ids).
6. **Return**. No mutation. Agent UI shows the suggestion as a badge with
   "Accept" / "Edit" / "Dismiss" actions.

### Files

Same pattern as Endpoint 1, swap `quotation` → `help-desk`. Reuses the same
Langfuse client + `LlmCallOptions.model` machinery from #1.

### Langfuse prompt `pms/helpdesk-triage`

> **System:** You are a help-desk triage assistant. Given a customer
> request and the available taxonomy (categories, valid workflow stages,
> priority enum), pick the best fit. Output JSON ONLY:
> `{suggestedPriority, suggestedCategoryId, suggestedWorkflowStageId, reasoning (<=2 sentences), confidence (0-1)}`.
> Choose ids ONLY from the provided lists; never invent. If unsure, prefer
> the lower priority and leave optional ids null.
>
> **User:** Request title: `{{title}}`. Description: `{{description}}`.
> Recent comments:
> `{{recent_comments_block}}`
>
> Available categories (id : name : description):
> `{{categories_block}}`
>
> Valid next workflow stages (id : name) from current `{{current_stage_name}}`:
> `{{stages_block}}`
>
> Return JSON.

---

## Langfuse client (shared by both endpoints)

A thin file in `apps/api/src/modules/ai-assistant/providers/langfuse.client.ts`,
no SDK dep — just `fetch`:

```ts
import { Injectable, Logger } from '@nestjs/common';
import { AiRuntimeConfigService } from '../ai-runtime-config.service';

interface LangfusePrompt {
  name: string;
  version: number;
  prompt: string;
  // Langfuse returns more fields; we only need these.
}

@Injectable()
export class LangfuseClient {
  private readonly logger = new Logger(LangfuseClient.name);
  private cache = new Map<string, { at: number; data: LangfusePrompt }>();
  private readonly ttlMs = 60_000;

  constructor(private readonly runtime: AiRuntimeConfigService) {}

  /** GET /api/public/v2/prompts/{name}?label=production */
  async getPrompt(name: string, label = 'production'): Promise<LangfusePrompt> {
    const cacheKey = `${name}@${label}`;
    const hit = this.cache.get(cacheKey);
    if (hit && Date.now() - hit.at < this.ttlMs) return hit.data;

    const c = await this.runtime.getEffective();
    if (!c.langfuseHost || !c.langfusePublicKey || !c.langfuseSecretKey) {
      throw new Error('Langfuse not configured');
    }
    const encoded = encodeURIComponent(name);
    const url = `${c.langfuseHost}/api/public/v2/prompts/${encoded}?label=${encodeURIComponent(label)}`;
    const auth = Buffer.from(`${c.langfusePublicKey}:${c.langfuseSecretKey}`).toString('base64');
    const res = await fetch(url, { headers: { Authorization: `Basic ${auth}` } });
    if (!res.ok) {
      throw new Error(`Langfuse ${name}@${label}: ${res.status} ${await res.text()}`);
    }
    const data = (await res.json()) as LangfusePrompt;
    this.cache.set(cacheKey, { at: Date.now(), data });
    return data;
  }
}

export function compileTemplate(template: string, vars: Record<string, string>): string {
  return template.replace(/\{\{\s*(\w+)\s*\}\}/g, (_, k) => vars[k] ?? '');
}
```

Wire it in `ai-assistant.module.ts` providers alongside `AiLlmClient`.

---

## Env additions (PMS)

`.env.example`:

```env
# Langfuse prompt management (https://langfuse.kleem.io for 1TechHub)
# Required for Tier 2+ AI features that fetch prompts from Langfuse.
# LANGFUSE_HOST=https://langfuse.kleem.io
# LANGFUSE_PUBLIC_KEY=
# LANGFUSE_SECRET_KEY=
```

The public/secret keys are the Langfuse project keys (separate from the
gateway virtual key). Pull from SSM in deployment.

---

## Permissions

Add two permission keys (the seed file in PMS that defines the existing
`ai-*:use` keys is the model — usually `database/seed.ts` or a permissions
table seed). New keys:

- `ai-quotations:use` — granted to sales roles by default
- `ai-helpdesk:use` — granted to help-desk agent roles by default

Existing blanket `ai:use` should also include them (legacy behavior).

---

## Testing

Each endpoint gets:

1. **Service unit test** — mock `AiLlmClient` to return canned JSON, assert
   the service builds the right `vars` map and parses the response.
2. **Controller e2e** — test 401 / 403 / 404 paths and a happy-path call
   with a stubbed Langfuse + LLM.

Existing patterns in `apps/api/src/modules/ai-assistant/tests/` show how
to mock these.

---

## Rollout sequence

1. **PR 1**: Langfuse client + `LlmCallOptions.model` override + env additions. No new endpoints yet — just plumbing. CI green.
2. **PR 2**: Quotation drafting endpoint + Langfuse prompt seed instructions. Smoke against `llm.kleem.io` from staging.
3. **PR 3**: Help-desk triage endpoint. Same shape.
4. **PR 4** (post-Tier 2 review): migrate existing Tier 1 inline prompts to Langfuse one by one.

Each PR is independently reviewable and reversible. Estimated effort: PR 1 ~half-day, PR 2 and PR 3 each ~half-day with tests.
