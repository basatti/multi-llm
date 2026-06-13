# PMS Tier 3 — Semantic search + embeddings

Design for the next-generation AI surface in PMS: natural-language search
and retrieval across the corpus of comments, activity logs, descriptions,
and uploaded documents. This is the foundation Tier 3 features depend on
(semantic search, contract-clause Q&A, knowledge-base-grounded responses).

Tier 3 is deferred until Tier 2 ships and there's measured demand —
embedding pipelines have meaningful infra and operational cost; we don't
build them on speculation.

---

## What "Tier 3" actually delivers

The high-leverage feature is **"find me X across everything PMS knows"**
where X is described in natural language, not exact-match keywords:

- *"contacts who mentioned pricing concerns last quarter"*
- *"all deals where the customer complained about timelines"*
- *"contracts with non-standard payment terms"*
- *"help-desk tickets similar to this one"* (clusters by topic)
- *"what did this customer say about our competitors?"*

These collapse to: turn the question into a vector, find the closest N
records, optionally re-rank, return citations.

Secondary uses on top of the same index:

- **Contract clause Q&A** — ask natural questions of a single contract's
  HTML snapshot.
- **Knowledge-base grounding** — when help-desk drafts replies (Tier 2 #2
  extended), pull the top-3 relevant KB articles into the prompt.
- **Anti-duplicate** — when an organization is created, search for similar
  existing ones to flag possible duplicates.

---

## Architectural decisions

### 1. Embeddings provider — gateway-routed Bedrock or self-hosted?

The platform open question from architecture.md §4.3 finally gets resolved
here. Three concrete options:

| Option | Latency | Cost | Operational |
|---|---|---|---|
| **AWS Bedrock Titan-Embeddings v2** routed via LiteLLM (`bedrock/amazon.titan-embed-text-v2:0`) | ~50-150 ms | $0.00002 / 1k tokens (pennies for typical PMS volumes) | Zero — managed service in our VPC, no GPU |
| **Cohere Embed v3** via LiteLLM | ~80-200 ms | $0.0001 / 1k tokens | Zero — managed |
| **Self-hosted on Ollama** (`nomic-embed-text` or `bge-m3`) | ~30-80 ms | covered by existing GPU box | One more model in Ollama; competes with chat models for VRAM |

**Recommended: Bedrock Titan v2 via LiteLLM.** Three reasons:

1. PMS embedding workload is bursty (indexer runs occasionally) and high
   per-call count (thousands of small records). Bedrock's per-token pricing
   matches that profile; our GPU box's value is in low-latency interactive
   chat, not batch indexing.
2. No VRAM pressure on the T4 — chat models stay hot.
3. Same gateway path; same key; same telemetry. Adds zero new infra.

The fallback (when LiteLLM's Bedrock backend is misconfigured): drop in
`nomic-embed-text` on Ollama via a model group. Hot-swappable per the
existing pattern.

### 2. Vector store — pgvector vs separate DB

PMS already uses PostgreSQL. **Use pgvector** unless we have a concrete
reason to add a second data system.

| | pgvector (Postgres extension) | Dedicated (Qdrant, Pinecone) |
|---|---|---|
| Setup | `CREATE EXTENSION vector;` + migration | New service to deploy, monitor, back up |
| Joins with existing tables | trivial (`WHERE deal.id = ?` alongside vector ANN) | requires cross-store assembly in app |
| ANN index | HNSW or IVFFlat — fine to PMS scale (<10M vectors) | optimized for billions |
| Backup | piggybacks on existing pg backup | separate |
| Cost | $0 additional | $50-200+/mo |

For the size of PMS (estimate: ~hundreds of thousands of comments,
activity rows, descriptions per workspace; ~10-100 workspaces), pgvector
HNSW gives sub-100 ms query latency comfortably. Switch later only if we
prove a bottleneck.

### 3. Index granularity — what gets a vector

Not everything; that's wasteful. The hit list:

| Source table | Field | Why |
|---|---|---|
| `comment` | `text` | The richest signal — internal notes, customer replies |
| `activity_log` | rendered `text` | The chronological story of every entity |
| `help_desk_request` | `description` + concatenated comment thread | Triage / "similar tickets" |
| `deal` | `description` + name | Discovery: "find deals about X" |
| `organization` | `description` + `name` | Anti-dup, similarity |
| `contact` | `description` + `name` + role | Same |
| `contract` | per-clause split of `htmlSnapshot` (one vector per clause, not per contract) | Clause-level Q&A |
| `help_desk_kb` | `body` (chunked at ~512 tokens) | Reply drafting grounding |

NOT indexed (initially):
- File attachments (PDFs etc.) — requires OCR pipeline first, defer.
- Task descriptions — small, low signal; revisit if users ask.
- Quotation introductions / T&C — these are AI-generated; don't index.

### 4. Indexing pipeline — push, not pull

Two parts:

1. **Backfill** — a one-time admin job that walks each source table and
   emits embeddings. Implement as a BullMQ job with progress logged per
   1k rows. Resumable via checkpoint cursor.
2. **Live updates** — every `INSERT` / `UPDATE` of an indexed field
   enqueues an embedding job for that single row. Use TypeORM
   subscribers (already a pattern in PMS) or `@nestjs/event-emitter`,
   whichever matches existing PMS conventions. Async — don't block writes.

Worker concurrency: bounded (e.g. 4-8 parallel) so backfill doesn't
monopolize gateway capacity. Tied into the existing `QUEUE.AI` BullMQ
queue, separate queue name (`QUEUE.EMBEDDING`).

### 5. Schema sketch (pgvector)

```sql
-- Single polymorphic vector table, scoped, with an HNSW index.
-- entity_type + entity_id + chunk_index uniquely identify a vector.
CREATE EXTENSION IF NOT EXISTS vector;

CREATE TABLE embedding (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  workspace_id uuid NOT NULL,                  -- multi-tenant isolation
  scope_id uuid NOT NULL,                      -- mirrors PMS scoping
  entity_type text NOT NULL,                   -- 'comment' | 'deal' | ...
  entity_id uuid NOT NULL,
  chunk_index int NOT NULL DEFAULT 0,          -- > 0 for chunked contracts/kb
  source_text text NOT NULL,                   -- the text that was embedded
  model_id text NOT NULL,                      -- e.g. 'bedrock/amazon.titan-embed-text-v2:0'
  model_version int NOT NULL,                  -- bump on model swap → triggers re-index
  embedding vector(1024) NOT NULL,             -- Titan v2 = 1024 dims
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (entity_type, entity_id, chunk_index, model_id, model_version)
);

CREATE INDEX embedding_hnsw_cosine
  ON embedding USING hnsw (embedding vector_cosine_ops)
  WITH (m = 16, ef_construction = 64);

-- Query-time filtering by workspace + scope is the common case; index those.
CREATE INDEX embedding_filter_idx ON embedding (workspace_id, scope_id, entity_type);
```

Scope filtering at query time is non-negotiable for security — never
return a record the caller's scope can't see. Tested in middleware:

```sql
SELECT entity_type, entity_id,
       1 - (embedding <=> $1) AS similarity
FROM embedding
WHERE workspace_id = $2
  AND scope_id = ANY($3)         -- allowedScopeIds from request
  AND entity_type = ANY($4)
ORDER BY embedding <=> $1
LIMIT 20;
```

### 6. Re-ranking (optional, do it for v2)

ANN returns approximate matches; for the top-K results, re-rank with a
cross-encoder for precision. Bedrock has `cohere.rerank-v3.5` — same
gateway path. Adds ~100 ms; meaningfully better top-3.

Defer in v1; add when users complain about ranking quality.

### 7. Query API

`POST /api/v1/ai/search/semantic`:

```jsonc
{
  "query": "deals about pricing concerns from Q2",
  "entityTypes": ["deal", "comment"],        // optional, defaults to all
  "limit": 20,
  "filters": {                               // optional, applied at SQL level
    "createdAfter": "2026-04-01",
    "ownerId": "..."
  }
}
```

Response:

```jsonc
{
  "results": [
    { "entityType": "deal", "entityId": "...", "similarity": 0.84,
      "preview": "...the customer pushed back hard on Q2 pricing...",
      "displayUrl": "/deals/abc123" },
    ...
  ],
  "queryEmbeddingModel": "bedrock/amazon.titan-embed-text-v2:0",
  "tookMs": 87
}
```

UI: NL-search bar on `/contacts`, `/deals`, `/help-desk` list pages.

### 8. Cost model

For a workspace with 1M indexed text rows averaging 200 tokens each:

- **Backfill (one-time):** 1M × 200 tokens = 200M tokens × $0.00002 = **$4 once.**
- **Live updates:** ~1k new rows/day → 200k tokens/day × $0.00002 = **$0.004/day = $1.20/year.**
- **Query:** each query embeds the prompt (~10-50 tokens) = ~$0.000001 per query. **Effectively free.**

The dominant cost is the one-time backfill. Per-workspace, per-deploy. Cheap.

Storage: 1M vectors × 1024 dims × 4 bytes = 4 GB per workspace. Add HNSW
index overhead (~1.5×). pgvector handles this on a t4g.small Postgres
without breaking a sweat.

---

## Rollout sequence

1. **Spike (1-2 days)** — pgvector POC on local PMS Postgres, embed 1k
   recent comments via the gateway, run a sample query, eyeball ranking
   quality. Fail-fast if Titan-v2-via-LiteLLM doesn't work as expected.
2. **PR 1: Schema + EmbeddingService** — migration, `EmbeddingsService`
   with `embedBatch()`, integration with `AiRuntimeConfigService`,
   tests.
3. **PR 2: Indexer worker** — TypeORM subscribers on the 8 source
   tables, BullMQ `embedding` queue, admin endpoint to trigger a backfill.
4. **PR 3: Search API + UI** — `POST /api/v1/ai/search/semantic`,
   permission `ai-search:use`, NL search bar on the list pages.
5. **PR 4: Re-ranker** — opt-in via query flag, default on once measured
   precision gain is real.

Each PR independently mergeable. Estimated effort: 1-2 weeks total for
the dev who picks it up, assuming Tier 2 has shipped and there's at least
one workspace's traffic data to validate ranking against.

---

## Open questions

1. **Multi-language**: should one `embedding` table mix English + Arabic
   vectors, or shard by language? Titan v2 is multilingual and benchmarks
   well on Arabic, so probably mixed. Revisit after measuring.
2. **PII**: comments / descriptions can contain PII (names, emails, phone
   numbers). Indexing them is fine; need to confirm the workspace owner
   is OK with embeddings hitting Bedrock (= AWS, not third-party).
   Bedrock data is contractually not used for model training. Document
   this clearly in PMS's AI Settings.
3. **Re-index on model swap**: if we move to a different embedding model
   later, the existing vectors are useless. Schema has `model_id` /
   `model_version` so we can re-index incrementally without dropping
   the table; need a UX for "background re-indexing N% complete."

---

## File pointers (when implementation starts)

- New module: `apps/api/src/modules/embeddings/`
  - `embeddings.module.ts`
  - `embeddings.service.ts` — `embedBatch()`, `embedSingle()`, `query()`
  - `entities/embedding.entity.ts`
  - `processors/embedding.processor.ts` — BullMQ worker
  - `subscribers/` — one per source table
- New endpoint group: `apps/api/src/modules/ai-assistant/ai-assistant.controller.ts`
  adds `/v1/ai/search/semantic` (the search API lives with other AI
  features for permission consistency).
