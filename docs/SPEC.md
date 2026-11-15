# Adaptive Mastery

Sign in, then explore one shared knowledge graph grown by an LLM neighborhood around each focus topic.

## Product

- Authentication uses Firebase. The API exchanges a Firebase ID token for its own JWT.
- There is one shared topic graph. A search merges into that universe; it does not create a private graph.
- A node has a UUID, canonical `name`, `name_key`, a standalone `description`, and an optional shared iconic `image_url` (PNG bytes generated on demand). Names are not globally unique when the model says two same-titled topics are different concepts.
- Edges are typed `parent`, `child`, `sibling`, or `acquaintance`, and are stored in both directions.
- Each signed-in user sets a total neighborhood budget (`total`, 8–32, default 16) and how many neighbors-of-neighbors (`extended`, 0–24, default 12) to show. The model chooses how many parents, siblings, children, and acquaintances to return (a bit of each).
- Focusing or opening a topic returns whatever neighbors already exist (`incomplete` when under the user’s total budget). A Railway worker runs `expand_neighborhood` only when the user explicitly requests neighbors.
- Expand uses two reusable LLM prompts plus deterministic retrieve: `neighborhood_v5` (invent related topics for the deficit, excluding existing neighbor titles) and `sameness_v3` (batched same-concept? → id or null). Learn bits use `content_bits_v1` separately.
- Scenarios: (1) new topic → retrieve → sameness → exists → under budget → neighborhood → retrieve/sameness per result → write; (2) new → retrieve → sameness → not exists → neighborhood → …; (3) existing focus → under budget → neighborhood → …; (4) new → retrieve → sameness → exists → budget met → Done; (5) existing focus → budget met → Done. Existing-tile expand skips focus sameness.
- Each topic can have shared learning bits (`learn`, `example`, `check`) generated on demand via an `expand_content` job. Opening Learn loads existing bits; if incomplete, the client may request expand. Bits are cached on the node for all users.
- Each topic can have one shared iconic image generated on demand via a `generate_image` job (Gemini Imagen or OpenAI Images from the user’s AI provider setting). The topic screen shows the image above the title and offers Generate / Regenerate.
- Each request stores hop distances and kinds for the returned neighborhood.
- Profile fields `username`, `full_name`, and `photo_url` live in `users.preferences.profile`. Learning XP/level on the HUD are placeholders until mastery tracking exists.

## API

- `POST /api/v1/auth/firebase`
- `GET /api/v1/me`
- `PATCH /api/v1/me` `{username?, full_name?, photo_url?, display_name?, timezone?}`
- `GET /api/v1/me/preferences`
- `PATCH /api/v1/me/preferences`
- `POST /api/v1/knowledge/focus` `{topic?}` or `{node_id?}` → graph (200); with `expand: true` and under budget → `{job_id}` (202)
- `GET /api/v1/knowledge/nodes?q=` existing-topic autocomplete (no LLM)
- `GET /api/v1/knowledge/nodes/{node_id}/content` → shared bits (`incomplete` when recipe incomplete)
- `POST /api/v1/knowledge/nodes/{node_id}/content` `{expand?: bool}` → content (200); with `expand: true` and incomplete → `{job_id}` (202)
- `GET /api/v1/knowledge/nodes/{node_id}/image` → `{image_url, incomplete}`
- `POST /api/v1/knowledge/nodes/{node_id}/image` `{generate?, regenerate?}` → metadata (200) or `{job_id}` (202)
- `GET /api/v1/knowledge/nodes/{node_id}/image/file` → PNG bytes (auth)
- `GET /api/v1/knowledge/graph` resume latest neighborhood only (no expand)
- `GET /api/v1/knowledge/graph/{focus_id}` existing neighborhood only (no expand)
- `GET /api/v1/jobs/{job_id}`
- `GET /api/v1/workspace/graph`
- `POST /api/v1/graph/extend` (410)
- `GET /health`

Graph payloads use UUID ids. Node `kind` is `parent`, `sibling`, `child`, `related`, `extended` (neighbors of neighbors), or `focus`. Edge `type` uses the stored relation names. The canvas always shows every direct neighbor, then up to the user’s `extended` count of unique neighbors-of-neighbors beside the direct they hang off.

## Client

Edge-to-edge neighborhood canvas with a top-left profile HUD (avatar, level, name, XP bar). Tapping the HUD opens a profile overlay with Settings, Logout, and learning placeholders. Settings is a Talivo-style sheet with App (appearance + neighborhood tile counts), Profile (username, full name, photo URL), and Account (email/password) tabs. A small neutral search FAB opens a field above the keyboard and lists matching existing topics as the user types; tapping one opens that node without an LLM expand. Submitting a new topic opens it immediately; the user requests neighbors explicitly. The topic drawer shows an optional hero image above the title, with Learn and Generate image actions (pulse placeholder while a `generate_image` job runs). Learn opens a sheet with learn · example · check bits (pulse placeholders while an `expand_content` job runs). While a job runs, a lower-left chip shows live progress. TT Ramillas is used only on hex tile labels and search result titles; the rest of the UI uses the platform font.
