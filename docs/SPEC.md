# Adaptive Mastery

Sign in, then view and extend one shared knowledge graph.

## Product

- Authentication uses Firebase. The API exchanges a Firebase ID token for its own JWT.
- There is one graph, slug `knowledge`. It is a set of nodes and edges shared by every signed-in user.
- A node is a concept: title, a short summary, a hierarchy level, a longer explanation of the range the topic covers, and a canonical key so the same idea is not stored twice. Level 1 is a broad domain, such as life sciences, physical health, social sciences, literature, life skills, psychology, mental wellbeing, mathematics, physical sciences, history, arts, technology, or language. A larger level is a more specific part. A broad topic such as parenting or dinosaurs is level 2.
- An edge is `contains`, `prerequisite`, or `related`.
- An extend request asks for more of the graph. The request stays pending while the worker asks the model, then while it adds the topics. The screen shows that pending generation and which of those steps is underway. The worker asks the model for an exhaustive graph of the real parts of that topic, several levels deep. It then places the request. A request that names a domain stays at level 1. Parenting sits under life skills, and dinosaurs sit under life sciences. A request that names a part of a topic already in the graph sits under that topic. Every other node from the request hangs under the requested topic, so the request adds one contains tree. Each node has a short title that names the subject, a level, and an explanation of the range it covers. Nothing is filled in from a fixed outline. An existing node is reused when its canonical key matches, or when its explanation already covers the requested idea and the new idea is not a more specific part. A longer explanation replaces a short placeholder. Contains and prerequisite edges that would cycle are dropped. Edges that do not connect two real nodes are dropped. After the merge, each node's level is one more than its depth in the contains tree, so a domain with no parent is level 1.
- Every signed-in user can read past extend requests, including who asked and whether the request succeeded. Deleting a past extend removes the nodes and edges that extend added. A node that already existed and was only reused stays. An edge that touches a deleted node is removed with that node.
- Any signed-in user can delete a node. The edges that touch that node are deleted with it. Other nodes stay. Past extend requests stay, with the parent cleared when it was the deleted node.

## API

- `POST /api/v1/auth/firebase`
- `GET /api/v1/me`
- `GET /api/v1/workspace/graph`
- `POST /api/v1/graph/extend`
- `DELETE /api/v1/graph/extend/{request_id}`
- `DELETE /api/v1/graph/nodes/{concept_id}`
- `GET /api/v1/jobs/{job_id}`
- `GET /health`

`GET /workspace/graph` returns `nodes`, `edges`, and `extend_requests`. Extend requests are newest first and include the author's display name.

## Client

The Flutter app has a sign-in screen and a graph screen. The graph is a fractal of hexagons. Level-1 domains are colored hexagons packed together into a larger hexagon. Zooming in splits each hexagon into the same kind of hexagons: its children, packed the same way inside it. Zooming further splits those the same way. Zoomed out, the domain labels are visible. Zooming in shows the labels of the level-2 hexagons, and zooming further shows the labels on the deeper hexagons. Tapping a label or a hexagon shows that node's explanation of the range it covers. While an extend is queued or running, the screen shows pending generation, the request, and the current step. A person can extend the whole graph or one node, delete a node and the edges connected to it, and open the list of past extends. Deleting one of those extends removes the nodes and edges it added.
