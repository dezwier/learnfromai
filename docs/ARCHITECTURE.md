# Architecture

Flutter talks to FastAPI with an API JWT. Firebase is used only to prove identity at `POST /api/v1/auth/firebase`. Graph extension runs in a Postgres-backed worker so the model call stays off the request.

```mermaid
flowchart LR
  flutter[Flutter]
  api[FastAPI]
  worker[Worker]
  cron[DailyCron]
  db[(PostgreSQL)]
  llm[Gemini or OpenAI]
  flutter -->|Firebase then API JWT| api
  api --> db
  cron -->|enqueue ranked jobs| db
  worker -->|SKIP LOCKED| db
  worker --> llm
```

The worker locks the graph row only while merging nodes and edges. It does not call the model inside that transaction. Provider choice comes from the user's `llm_provider` preference (Gemini or OpenAI/`gpt-5-mini`), falling back to `LLM_PROVIDER`. Topic images use the same preference for generation: Gemini Imagen or OpenAI Images (`generate_image` job). Uploaded topic images skip the worker and write full + thumb bytes on the knowledge node immediately. Profile photos are uploaded to `users.photo_bytes` and served at `/me/photo`. Today each topic has one iconic image; a multi-visual gallery (testing variants) is anticipated but not implemented.

A separate Railway **cron** service (`python -m app.cron`, schedule `0 6 * * *`) ranks tiles from user–tile affinity and enqueues top neighbor/learn jobs into `generation_jobs`. It does not call the LLM; the always-on worker runs those jobs.

## Expand orchestrator

One `expand_neighborhood` job. Shared boxes: **retrieve** (deterministic), **Sameness LLM** (`sameness_v3`), **Neighborhood LLM** (`neighborhood_v6`), **Under budget**, **Write**, **Done**.

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
- `content` — shared atomic learning packs (`pack_index` + learn / typed checks) and `expand_content` jobs
- `graph_extend` — extend requests and the merge
- `platform` — jobs, LLM client, quota, worker heartbeat
- `ranking` — user–tile affinity, neighbor/learn job scores, daily cron enqueue + `cron_runs`
- `user_events` — topic events and profile affinity clustering

## Tables

- `users`
- `graphs` — one row, slug `knowledge`
- `concepts` — nodes, with `title`, `summary`, and `canonical_key`
- `edges` — `from_concept_id`, `to_concept_id`, `type`
- `extend_requests` — one row per request, from any user
- `knowledge_nodes`, `knowledge_edges`, `knowledge_bits`
- `generation_jobs`, `generation_job_watchers`, `llm_usage`, `worker_heartbeats`
- `user_topic_events`, `cron_runs`
