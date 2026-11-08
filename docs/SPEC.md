# Adaptive Mastery

Sign in, then view and extend one shared knowledge graph.

## Product

- Authentication uses Firebase. The API exchanges a Firebase ID token for its own JWT.
- There is one graph, slug `knowledge`. It is a set of nodes and edges shared by every signed-in user.
- A node is a concept: title, a short summary, a hierarchy level, a longer explanation of the range the topic covers, and a canonical key so the same idea is not stored twice. Level 0 is the broadest topic. A larger level is a more specific part.
- An edge is `contains`, `prerequisite`, or `related`.
- An extend request asks for more of the graph. The worker builds an exhaustive graph of the real parts of that topic, several levels deep: the subject, the sections of its encyclopedia article, and the articles those sections open into. Each node has a short title that names the subject, a level, and an explanation of the range it covers. When a Gemini key is configured, the model builds that graph instead. Nothing is filled in from a fixed outline. An existing node is reused when its canonical key matches, or when its explanation already covers the requested idea and the new idea is not a more specific part. A longer explanation replaces a short placeholder. Contains and prerequisite edges that would cycle are dropped. Edges that do not connect two real nodes are dropped. After the merge, each node's level is the depth of the contains tree.
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

The Flutter app has a sign-in screen and a graph screen. The graph is an expandable tree: a topic starts open so its parts are visible, and each part opens to show the next level. Titles stay a readable size. Tapping a topic shows its explanation of the range it covers. A person can extend the whole graph or one node, delete a node and the edges connected to it, delete every node and edge from settings, and open the list of past extends.
