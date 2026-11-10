# Adaptive Mastery

Sign in, then explore one shared knowledge graph built from Wikidata classes.

## Product

- Authentication uses Firebase. The API exchanges a Firebase ID token for its own JWT.
- There is one item graph, shared by every signed-in user. A search does not create a private graph.
- An item is a Wikidata entity: stable Q number, title, and an optional short description. Identity is the Qid, not the title.
- An edge is `parent_child` and points from the preferred parent to the child. Taxa use `P171`; other items use `P279`. The walk stops at these domain roots: Life (organism Q7239), physical world (Q223557), places (Q2221906), people (Q215627), organizations (Q43229), events (Q1190554), works (Q386724), knowledge (Q11862829), technology (Q11016), languages (Q34770), ideas (Q21484471).
- Searching a topic resolves it to a Wikidata item, then loads that item, its preferred parents, and a short list of direct children (about eight, by Wikipedia coverage). Siblings are not auto-fetched; they appear when those topics are searched later. Wikimedia maintenance items and unlabeled rows are left out. Cycles are not walked twice.
- Items and edges are stored in PostgreSQL. A direction that was fully fetched inside the last 30 days is reused. An unfinished or stale direction is fetched again. An unfinished fetch is not treated as the full set of relationships.
- The same item row is reused when another topic reaches it. Repeated searches do not insert a second row for the same Qid.
- Each request stores the shortest-path hop distance of every returned node to the resolved focus. Distances belong to that request; they are not overwritten on the item.
- Graph structure is not generated, rearranged, or filtered by a model. `POST /api/v1/graph/extend` no longer adds nodes.
- Older concept rows, and the edges between them, stay in the database. They are not shown as Wikidata items.

## API

- `POST /api/v1/auth/firebase`
- `GET /api/v1/me`
- `GET /api/v1/knowledge/graph` (resume the signed-in user's latest focus)
- `GET /api/v1/knowledge/graph?topic=Dinosaurs&up_depth=2&down_depth=2`
- `GET /api/v1/knowledge/graph?category_id=430&up_depth=2&down_depth=2`
- `GET /api/v1/workspace/graph`
- `POST /api/v1/graph/extend` (retired; responds 410)
- `DELETE /api/v1/graph/extend/{request_id}`
- `DELETE /api/v1/graph/nodes/{concept_id}`
- `GET /api/v1/jobs/{job_id}`
- `GET /health`

`GET /knowledge/graph` returns `focus_node_id`, `incomplete`, `nodes`, and `edges`. Node ids are Wikidata Q numbers. `depth` is relative to the focus: negative above it, zero on it, positive below it. `distance` is the unsigned hop count to the focus. Edges run from parent to child. A search that has one clear head (far more sitelinks, preferably a class or taxon) opens that item. Only a real tie returns 409 with `details.candidates` (`wikidata_qid`, `title`, `description`). No match returns 404.

`GET /workspace/graph` still returns the older concept nodes, edges, and extend requests.

## Client

The Flutter app has a sign-in screen and a hex map. Opening the app resumes the person's latest focus from the shared graph. Searching a topic shows that topic split into its main children. Zooming out collapses into the parent hex. Tapping a child focuses it and loads its own children. Labels stay a fixed screen size and appear only when a hex has room.
