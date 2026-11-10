# Adaptive Mastery

Sign in, then explore one shared knowledge graph grown by an LLM neighborhood around each focus topic.

## Product

- Authentication uses Firebase. The API exchanges a Firebase ID token for its own JWT.
- There is one shared topic graph. A search merges into that universe; it does not create a private graph.
- A node has a UUID, canonical `name`, `name_key`, and a standalone `description`. Names are not globally unique when the model says two same-titled topics are different concepts.
- Edges are typed `parent`, `child`, `sibling`, or `acquaintance`, and are stored in both directions.
- Each signed-in user sets how many parents (1–2), siblings (2–3), children (3–5), and acquaintances (3–5) a complete neighborhood needs. Defaults are 2 / 3 / 4 / 4.
- Focusing a topic that already has enough relations for those settings returns the graph immediately. Otherwise a Railway worker runs an `expand_neighborhood` job: generate topics, merge by `name_key` then LLM sameness, write missing bidirectional edges, and report progress.
- Each request stores hop distances and kinds for the returned neighborhood.

## API

- `POST /api/v1/auth/firebase`
- `GET /api/v1/me`
- `GET /api/v1/me/preferences`
- `PATCH /api/v1/me/preferences`
- `POST /api/v1/knowledge/focus` `{topic?}` or `{node_id?}` → graph (200) or `{job_id}` (202)
- `GET /api/v1/knowledge/graph` resume latest (may also 202)
- `GET /api/v1/knowledge/graph/{focus_id}`
- `GET /api/v1/jobs/{job_id}`
- `GET /api/v1/workspace/graph`
- `POST /api/v1/graph/extend` (410)
- `GET /health`

Graph payloads use UUID ids. Node `kind` is `parent`, `sibling`, `child`, `related`, or `focus`. Edge `type` uses the stored relation names.

## Client

Neighborhood canvas: parents above, siblings beside the focus, related farther out, children below. Colors: parent blue, sibling violet, child green, related amber, focus primary. Search is a bottom-right FAB that opens a field above the keyboard. While a job runs, a modal barrier shows live progress. A gear opens neighborhood size settings.
