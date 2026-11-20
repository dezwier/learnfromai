# Adaptive Mastery

Sign in, then explore one shared knowledge graph grown by an LLM neighborhood around each focus topic.

## Product

- Authentication uses Firebase. The API exchanges a Firebase ID token for its own JWT.
- There is one shared topic graph. A search merges into that universe; it does not create a private graph.
- A node has a UUID, canonical `name`, `name_key`, a standalone `description`, and an optional shared iconic `image_url` (PNG bytes generated or uploaded on demand). Names are not globally unique when the model says two same-titled topics are different concepts.
- Edges are typed `parent`, `child`, `sibling`, or `acquaintance`, and are stored in both directions.
- Each signed-in user sets a total neighborhood budget (`total`, 8–32, default 16) and how many neighbors-of-neighbors (`extended`, 0–24, default 12) to show. The model chooses how many parents, siblings, children, and acquaintances to return (a bit of each).
- Focusing or opening a topic returns whatever neighbors already exist (`incomplete` when under the user’s total budget). A Railway worker runs `expand_neighborhood` when the user explicitly requests neighbors, and a separate daily Railway cron may also enqueue shared expand/content jobs from ranked affinity (defaults: 5 neighbor + 10 learn per day). Cron only enqueues; the always-on worker runs the LLM work.
- Expand uses two reusable LLM prompts plus deterministic retrieve: `neighborhood_v5` (invent related topics for the deficit, excluding existing neighbor titles) and `sameness_v3` (batched same-concept? → id or null). Learn packs use `content_bits_v3` separately.
- Scenarios: (1) new topic → retrieve → sameness → exists → under budget → neighborhood → retrieve/sameness per result → write; (2) new → retrieve → sameness → not exists → neighborhood → …; (3) existing focus → under budget → neighborhood → …; (4) new → retrieve → sameness → exists → budget met → Done; (5) existing focus → budget met → Done. Existing-tile expand skips focus sameness.
- Each topic can have many shared **atomic learning packs**. One pack is stored as `learn` + `check1` + `check2` + `check3` with a `pack_index` (existing rows are pack `1`). The learn bit is a standalone takeaway; each check has a `type` of `mc`, `true_false`, or `cloze`. For the learner, a pack is **atomically complete** after `learn` + **any one** check (randomly chosen); quiz results stay in `user_topic_events` for a future retention track. Packs are generated on demand via `expand_content`. `POST …/content` with `{expand: true, new_pack: true}` adds another pack only when every existing pack is content-complete. Generation avoids overlapping prior packs on the topic and neighbor topics. Bits are cached on the node for all users. Legacy kinds `example` and `check` may still exist; `check` is treated as `check1`. Legacy check bodies without `type` are treated as `mc`.
- **Learning track:** tapping the focus tile opens a single-card path. `GET /me/learning-next?seed_node_id=` picks the next unlearned pack on the seed or a direct neighbor (exploit probability `learn_track_exploit_p`, default 0.7, else affinity-weighted explore). If none exist, the client enqueues content expand for the seed and pulses until ready. After the quiz, a Next button advances with the finished node as the new seed. Long-press → action drawer → **Show atomic learning** opens the multi-pack review deck for that topic only.
- Each topic has at most one shared iconic image today (generate via AI or upload). One generation/upload produces a full (~1024) asset for the topic screen and a 512px JPEG thumb for hex tiles. The topic screen shows the square image above the title; the image button opens Generate / Upload (or Regenerate / Replace when an image already exists). Hex tiles fill with the thumb plus a scrim for title readability.
- **Later (not built):** a topic may hold multiple visuals (gallery / testing variants) with one chosen primary for tiles and hero. Keep the single-image fields as the primary until that gallery lands.
- Each request stores hop distances and kinds for the returned neighborhood.
- User–topic interactions are appended to `user_topic_events` (per user): opening a neighborhood writes `focus`; opening the topic screen writes `open` with `source` `graph`, `search`, or `list` (related topics on the open topic screen); the Learn sheet records `learn`, `check1`, `check2`, and `check3` events with `pack_index` in the payload (checks include `correct` plus `choice_index` / `answer_bool` / `answer_text` by type). Legacy `example` events may still exist. This log is the basis for later trajectory and content generation; it does not replace `knowledge_requests` resume snapshots.
- One user–tile affinity measure (`AFFINITY_W_FOCUS` / `AFFINITY_W_OPEN` / `AFFINITY_W_NEW` / `AFFINITY_W_NEIGHBOR` / `AFFINITY_HALF_LIFE_DAYS`; soft half-life only): `own=w_focus*focus+w_open*open`, then `affinity(u,t)=(own+w_neighbor*Σ_neighbors own+w_new*recency(node_age))*recency(last_focus_or_open)` (`w_neighbor` default 0.5). Learn/check/pack events do not affect affinity (they still feed the learning track and `completed_packs`). Profile map (`GET /me/topic-affinity`) uses that score and clusters top topics by induced `knowledge_edges`. Cron neighbor jobs use `CRON_NEIGHBOR_W_COUNT_PENALTY` (`score=affinity/(1+penalty*neighbors)`); pack jobs use `CRON_LEARN_W_PACK_PENALTY` + `CRON_LEARN_W_NEIGHBOR_BOOST` (`score=affinity*(1+boost*neighbors)/(1+penalty*packs)`). Collaborative filtering can later replace `affinity(u,t)` behind the same interface.
- Profile fields `username`, `full_name`, and `photo_url` live in `users.preferences.profile`. Uploaded avatars are stored as `users.photo_bytes` and served at `GET /me/photo` (`photo_url` is that API path). Learning XP/level on the HUD are placeholders until mastery tracking exists. Admins see the last cron run (tiles expanded / packs enqueued) in App settings via `GET /admin/cron-runs/latest`.

## API

- `POST /api/v1/auth/firebase`
- `GET /api/v1/me`
- `PATCH /api/v1/me` `{username?, full_name?, photo_url?, display_name?, timezone?}`
- `GET /api/v1/me/photo` → JPEG bytes (auth)
- `PUT /api/v1/me/photo` multipart `file` → user payload with `photo_url`
- `DELETE /api/v1/me/photo`
- `GET /api/v1/me/preferences`
- `PATCH /api/v1/me/preferences`
- `POST /api/v1/me/events` `{events: [{node_id, kind, occurred_at?, payload?}]}` → `{recorded, ids}` (client `open` / learn / example / check; `open` payload `{source: graph|search|list}`; `focus` is written server-side on neighborhood open)
- `GET /api/v1/me/topic-affinity?limit=24` → `{nodes, clusters, edges}` for the profile affinity map (each node: `rank`, `affinity`, `breakdown` `{focus,open,neighbor,new,recency}`)
- `GET /api/v1/me/learning-next?seed_node_id=` → `{status: ready, node_id, title, pack_index, pack, affinity, completed_packs}` or `{status: generate, node_id, title}` when seed+neighbors have no unlearned packs
- `GET /api/v1/admin/cron-runs/latest` → last daily ranking cron summary (403 unless `is_admin`)
- `POST /api/v1/admin/cron-runs/run` → run the ranking cron now and return its summary (403 unless `is_admin`)
- `POST /api/v1/knowledge/focus` `{topic?}` or `{node_id?}` → graph (200); with `expand: true` and under budget → `{job_id}` (202)
- `GET /api/v1/knowledge/nodes?q=` existing-topic autocomplete (no LLM)
- `GET /api/v1/knowledge/nodes/{node_id}/content` → `{pack_count, packs: [{pack_index, incomplete, title, bits}], completed_packs, incomplete}` (`completed_packs` = pack indexes where the user logged learn + any one check; `incomplete` when no packs or any pack content-incomplete)
- `POST /api/v1/knowledge/nodes/{node_id}/content` `{expand?: bool, new_pack?: bool}` → content (200); with `expand: true` and missing/incomplete pack → `{job_id, pack_index}` (202); `new_pack: true` only when all packs complete (else 422)
- `GET /api/v1/knowledge/nodes/{node_id}/image` → `{image_url, incomplete}`
- `POST /api/v1/knowledge/nodes/{node_id}/image` `{generate?, regenerate?}` → metadata (200) or `{job_id}` (202)
- `PUT /api/v1/knowledge/nodes/{node_id}/image` multipart `file` → metadata (200)
- `GET /api/v1/knowledge/nodes/{node_id}/image/file?variant=full|thumb` → PNG (full) or JPEG (thumb) bytes (auth)
- `GET /api/v1/knowledge/graph` resume latest neighborhood only (no expand)
- `GET /api/v1/knowledge/graph/{focus_id}` existing neighborhood only (no expand)
- `GET /api/v1/jobs/{job_id}`
- `GET /api/v1/workspace/graph`
- `POST /api/v1/graph/extend` (410)
- `GET /health`

Graph payloads use UUID ids. Node `kind` is `parent`, `sibling`, `child`, `related`, `extended` (neighbors of neighbors), or `focus`. Edge `type` uses the stored relation names. The canvas always shows every direct neighbor, then up to the user’s `extended` count of unique neighbors-of-neighbors beside the direct they hang off. Only the focus node includes `description` and full `image_url`; every node may include `image_thumb_url` for tiles.

## Client

Edge-to-edge neighborhood canvas with a top-left profile HUD (avatar, level, name, XP bar). Tapping the HUD opens a profile overlay with Settings, Logout, a topic-affinity badge list under Learning about (one color per cluster from `GET /me/topic-affinity`; tap focuses that topic on the canvas), and a Practice placeholder. Settings is a Talivo-style sheet with App (appearance + neighborhood tile counts), Profile (username, full name, photo upload), and Account (email/password) tabs. A small neutral search FAB opens a field above the keyboard and lists matching existing topics; tapping or submitting focuses that node and starts the learning track (`open` from `search`). Tapping the current focus tile starts the learning track (`open` from `graph`): one flip card (learn front, random check back), then a large Next to continue the organic path. Long-press opens the topic action drawer (image, manage, relations, generate, **Show atomic learning** for the multi-pack review deck of that topic). Pulse placeholders run while an `expand_content` job fills an empty track. Step/check events (including `pack_index`) go to `/me/events`. While a job runs, a lower-left chip shows live progress. TT Ramillas is used only on hex tile labels and search result titles; the rest of the UI uses the platform font.
