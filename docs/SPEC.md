# Adaptive Mastery

Sign in, then view and extend one shared knowledge graph.

## Product

- Authentication uses Firebase. The API exchanges a Firebase ID token for its own JWT.
- There is one graph, slug `knowledge`. It is a set of nodes and edges shared by every signed-in user.
- A node is a concept: title, a short summary, a hierarchy level, a longer explanation of the range the topic covers, and a canonical key so the same idea is not stored twice. Level 0 is the broadest topic. A larger level is a more specific part.
- An edge is `contains`, `prerequisite`, or `related`.
- An extend request asks for more of the graph. The worker asks the model for an exhaustive graph of the real parts of that topic, several levels deep. Each node has a short title that names the subject, a level, and an explanation of the range it covers. Nothing is filled in from a fixed outline. An existing node is reused when its canonical key matches, or when its explanation already covers the requested idea and the new idea is not a more specific part. A longer explanation replaces a short placeholder. Contains and prerequisite edges that would cycle are dropped. Edges that do not connect two real nodes are dropped. After the merge, each node's level is the depth of the contains tree.
- Every signed-in user can read past extend requests, including who asked and whether the request succeeded.
- Any signed-in user can delete a node. The edges that touch that node are deleted with it. Other nodes stay. Past extend requests stay, with the parent cleared when it was the deleted node.
- Settings can delete every node and every edge. Past extend requests stay.

## API

- `POST /api/v1/auth/firebase`
- `GET /api/v1/me`
- `GET /api/v1/workspace/graph`
- `POST /api/v1/graph/extend`
- `DELETE /api/v1/graph`
- `DELETE /api/v1/graph/nodes/{concept_id}`
- `GET /api/v1/jobs/{job_id}`
- `GET /health`

`GET /workspace/graph` returns `nodes`, `edges`, and `extend_requests`. Extend requests are newest first and include the author's display name.

## Client

The Flutter app has a sign-in screen and a graph screen. The graph draws solid edges. Prerequisite edges are heavier. Zoomed out, only the broadest level is visible. Zooming in reveals the next level, and node text stays a readable size. Nodes that share an edge are drawn together, and a piece with no path to the others sits in its own frame. Tapping a node shows its explanation of the range it covers. A person can extend the whole graph or one node, delete a node and the edges connected to it, delete every node and edge from settings, and open the list of past extends.
