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
- Profile fields `username`, `full_name`, and `photo_url` live in `users.preferences.profile`. Learning XP/level on the HUD are placeholders until mastery tracking exists.

## API

- `POST /api/v1/auth/firebase`
- `GET /api/v1/me`
- `PATCH /api/v1/me` `{username?, full_name?, photo_url?, display_name?, timezone?}`
- `GET /api/v1/me/preferences`
- `PATCH /api/v1/me/preferences`
- `POST /api/v1/knowledge/focus` `{topic?}` or `{node_id?}` → graph (200) or `{job_id}` (202)
- `GET /api/v1/knowledge/nodes?q=` existing-topic autocomplete (no LLM)
- `GET /api/v1/knowledge/graph` resume latest (may also 202)
- `GET /api/v1/knowledge/graph/{focus_id}` existing neighborhood only (no expand)
- `GET /api/v1/jobs/{job_id}`
- `GET /api/v1/workspace/graph`
- `POST /api/v1/graph/extend` (410)
- `GET /health`

Graph payloads use UUID ids. Node `kind` is `parent`, `sibling`, `child`, `related`, `extended` (neighbors of neighbors), or `focus`. Edge `type` uses the stored relation names. The canvas places direct neighbors first, then fills remaining tiles with unique `extended` nodes beside the direct neighbor they hang off.

## Client

Edge-to-edge neighborhood canvas with a top-left profile HUD (avatar, level, name, XP bar). Tapping the HUD opens a profile overlay with Settings, Logout, and learning placeholders. Settings is a Talivo-style sheet with App (appearance + neighborhood tile counts), Profile (username, full name, photo URL), and Account (email/password) tabs. A small neutral search FAB opens a field above the keyboard and lists matching existing topics as the user types; tapping one opens that node without an LLM expand. Submitting a new topic still focuses via the worker. While a job runs, a lower-left chip shows live progress. TT Ramillas is used only on hex tile labels and search result titles; the rest of the UI uses the platform font.
