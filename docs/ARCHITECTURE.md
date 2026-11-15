# Architecture

Flutter talks to FastAPI with an API JWT. Firebase is used only to prove identity at `POST /api/v1/auth/firebase`. Graph extension runs in a Postgres-backed worker so the model call stays off the request.

```mermaid
flowchart LR
  flutter[Flutter]
  api[FastAPI]
  worker[Worker]
  db[(PostgreSQL)]
  gemini[Gemini]
  flutter -->|Firebase then API JWT| api
  api --> db
  worker -->|SKIP LOCKED| db
  worker --> gemini
```

The worker locks the graph row only while merging nodes and edges. It does not call the model inside that transaction.

## Expand orchestrator

One `expand_neighborhood` job. Shared boxes: **retrieve** (deterministic), **Sameness LLM** (`sameness_v3`), **Neighborhood LLM** (`neighborhood_v5`), **Under budget**, **Write**, **Done**.

```mermaid
flowchart TD
  existing[Existing focus]
  under[Under budget]
  retrieve[retrieve]
  sameness[Sameness LLM]
  neighborhood[Neighborhood LLM]
  write[Write]
  done[Done]

  existing -->|yes| under
  existing -->|no| retrieve
  retrieve -->|ambiguous| sameness
  retrieve -->|clear reuse| under
  retrieve -->|clear new| neighborhood
  retrieve -->|clear neighbor| write
  sameness -->|reuse| under
  sameness -->|new| neighborhood
  sameness -->|neighbor| write
  under -->|need more| neighborhood
  under -->|complete| done
  neighborhood -->|each result| retrieve
  write --> done
```

## Modules

- `accounts` — Firebase exchange and users
- `knowledge_graph` — the shared graph, nodes, edges, and the workspace payload
- `content` — shared learn / example / check bits and `expand_content` jobs
- `graph_extend` — extend requests and the merge
- `platform` — jobs, LLM client, quota, worker heartbeat

## Tables

- `users`
- `graphs` — one row, slug `knowledge`
- `concepts` — nodes, with `title`, `summary`, and `canonical_key`
- `edges` — `from_concept_id`, `to_concept_id`, `type`
- `extend_requests` — one row per request, from any user
- `knowledge_nodes`, `knowledge_edges`, `knowledge_bits`
- `generation_jobs`, `generation_job_watchers`, `llm_usage`, `worker_heartbeats`
