# Adaptive Mastery

Sign in, then explore one shared knowledge graph built from Wikipedia categories.

## Product

- Authentication uses Firebase. The API exchanges a Firebase ID token for its own JWT.
- There is one category graph, shared by every signed-in user. A search does not create a private graph.
- A category is a Wikipedia category: stable page id, title, and an optional short description. Identity is the page id, not the title.
- An edge is `parent_child` and points from the parent category to the child category. A category may have several parents. The structure is a directed graph, not a tree.
- Searching a topic resolves it to a Wikipedia category, then loads that category, its parents, and its subcategories. The default reach is 2 categories upstream and 2 downstream. Hidden categories are left out when Wikipedia marks them hidden. Cycles are not walked twice.
- Categories and edges are stored in PostgreSQL. A direction that was fully fetched inside the last 30 days is reused. An unfinished or stale direction is fetched again. An unfinished fetch is not treated as the full set of relationships.
- The same category row is reused when another topic reaches it. Repeated searches do not insert a second row for the same Wikipedia page id.
- Graph structure is not generated, rearranged, or filtered by a model. `POST /api/v1/graph/extend` no longer adds nodes.
- Older concept rows, and the edges between them, stay in the database. A concept is linked to a category only when the titles are the same idea. Its title, explanation, level, and any progress that points at the concept stay as they are. A concept that does not match a category stays, and it is not shown as a Wikipedia category.

## API

- `POST /api/v1/auth/firebase`
- `GET /api/v1/me`
- `GET /api/v1/knowledge/graph?topic=Dinosaurs&up_depth=2&down_depth=2`
- `GET /api/v1/knowledge/graph?category_id=123&up_depth=2&down_depth=2`
- `GET /api/v1/workspace/graph`
- `POST /api/v1/graph/extend` (retired; responds 410)
- `DELETE /api/v1/graph/extend/{request_id}`
- `DELETE /api/v1/graph/nodes/{concept_id}`
- `GET /api/v1/jobs/{job_id}`
- `GET /health`

`GET /knowledge/graph` returns `focus_node_id`, `incomplete`, `nodes`, and `edges`. Node ids are Wikipedia page ids. `depth` is relative to the focus: negative above it, zero on it, positive below it. Edges run from parent to child. Several matches return 409 with `details.candidates`. No match returns 404.

`GET /workspace/graph` still returns the older concept nodes, edges, and extend requests.

## Client

The Flutter app has a sign-in screen and a category graph. The person searches for a topic, picks a category when Wikipedia returns more than one match, and sees parents above the selected category and children below it. Tapping a category focuses it and loads its surroundings from the same shared graph. Pinch zooms and drag pans. A previous-category control returns to the prior focus. A dense category shows a limited number of children until the person chooses Show more. The full set of relationships stays in the response.
