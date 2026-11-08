# Adaptive Mastery

Sign in, then view and extend one shared knowledge graph.

## Product

- Authentication uses Firebase. The API exchanges a Firebase ID token for its own JWT.
- There is one graph, slug `knowledge`. It is a set of nodes and edges shared by every signed-in user.
- A node is a concept: title, summary, and a canonical key so the same idea is not stored twice.
- An edge is `contains`, `prerequisite`, or `related`.
- An extend request asks for more of the graph. The worker asks the model for the nodes and edges that cover the request, then merges them into the graph immediately. Matching canonical keys reuse the existing node. Contains and prerequisite edges that would cycle are dropped. Edges that do not connect two real nodes are dropped.
- Every signed-in user can read past extend requests, including who asked and whether the request succeeded.
- Any signed-in user can delete a node. The edges that touch that node are deleted with it. Other nodes stay. Past extend requests stay, with the parent cleared when it was the deleted node.

## API

- `POST /api/v1/auth/firebase`
- `GET /api/v1/me`
- `GET /api/v1/workspace/graph`
- `POST /api/v1/graph/extend`
- `DELETE /api/v1/graph/nodes/{concept_id}`
- `GET /api/v1/jobs/{job_id}`
- `GET /health`

`GET /workspace/graph` returns `nodes`, `edges`, and `extend_requests`. Extend requests are newest first and include the author's display name.

## Client

The Flutter app has a sign-in screen and a graph screen. The graph draws solid edges. Prerequisite edges are heavier. Nodes that share an edge are drawn together, and a piece with no path to the others sits in its own frame. A person can extend the whole graph or one node, delete a node and the edges connected to it, and open the list of past extends.
