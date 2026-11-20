from app.features.accounts.firebase_auth import verify_firebase_id_token
from app.features.graph_extend.models import ExtendRequest
from app.features.knowledge_graph.models import Concept, Edge, Graph
from app.features.knowledge_graph.service import shared_graph


def test_health(client):
    assert client.get("/health").json()["status"] == "ok"


def test_me_and_firebase_exchange(client, monkeypatch):
    monkeypatch.setattr(
        "app.features.accounts.firebase_auth.verify_firebase_id_token",
        lambda token: {"uid": "firebase-1", "email": "ada@example.com", "name": "Ada"},
    )
    _ = verify_firebase_id_token
    response = client.post("/api/v1/auth/firebase", json={"id_token": "token"})
    assert response.status_code == 200
    token = response.json()["access_token"]
    me = client.get("/api/v1/me", headers={"Authorization": f"Bearer {token}"})
    assert me.status_code == 200
    assert me.json()["display_name"] == "Ada"
    assert client.get("/api/v1/me").status_code == 401


def test_extend_no_longer_generates_a_graph(client, auth):
    created = client.post("/api/v1/graph/extend", headers=auth, json={"instruction": "Dinosaurs"})
    assert created.status_code == 410
    assert created.json()["code"] == "GONE"
    workspace = client.get("/api/v1/workspace/graph", headers=auth).json()
    assert workspace["nodes"] == []
    assert workspace["edges"] == []


def test_openapi_is_auth_and_graph(client):
    paths = client.get("/openapi.json").json()["paths"]
    assert "/api/v1/auth/firebase" in paths
    assert "/api/v1/me" in paths
    assert "/api/v1/workspace/graph" in paths
    assert "/api/v1/knowledge/graph" in paths
    assert "/api/v1/graph/extend" in paths
    assert "/api/v1/graph/nodes/{concept_id}" in paths
    assert "delete" in paths["/api/v1/graph/extend/{request_id}"]
    assert "/api/v1/graph" not in paths
    assert "/api/v1/goals" not in paths
    assert "/api/v1/me/reviews/due" in paths
    assert "/api/v1/me/reviews/distribution" in paths
    assert "/api/v1/me/reviews/submit" in paths
    assert "/api/v1/mastery/overview" not in paths


def test_delete_node_removes_its_edges(client, auth, other_auth, session, user, other_user):
    _seed_legacy(session, user, other_user)
    with_child = client.get("/api/v1/workspace/graph", headers=auth).json()
    child_titles = {node["title"]: node["concept_id"] for node in with_child["nodes"]}
    parent_id = child_titles["Dinosaurs"]
    target = child_titles["Birds"]
    edge_count = len(with_child["edges"])

    removed = client.delete(f"/api/v1/graph/nodes/{target}", headers=other_auth)
    assert removed.status_code == 200
    assert removed.json()["removed_edges"] >= 1

    after = client.get("/api/v1/workspace/graph", headers=auth).json()
    remaining = {node["title"] for node in after["nodes"]}
    assert "Birds" not in remaining
    assert "Dinosaurs" in remaining
    assert all(edge["from_concept_id"] != target and edge["to_concept_id"] != target for edge in after["edges"])
    assert len(after["edges"]) < edge_count
    assert any(item["instruction"] == "Dinosaurs" for item in after["extend_requests"])

    deleted_parent = client.delete(f"/api/v1/graph/nodes/{parent_id}", headers=auth)
    assert deleted_parent.status_code == 200
    cleared = client.get("/api/v1/workspace/graph", headers=other_auth).json()
    assert "Dinosaurs" not in {node["title"] for node in cleared["nodes"]}
    assert "Birds" not in {node["title"] for node in cleared["nodes"]}
    birds = next(item for item in cleared["extend_requests"] if item["instruction"] == "Birds")
    assert birds["parent_concept_id"] is None
    assert all(edge["from_concept_id"] != parent_id and edge["to_concept_id"] != parent_id for edge in cleared["edges"])

    missing = client.delete(f"/api/v1/graph/nodes/{target}", headers=auth)
    assert missing.status_code == 404
    assert client.delete(f"/api/v1/graph/nodes/{target}").status_code == 401


def test_delete_node_removes_edges_recorded_on_another_graph(client, auth, session, user):
    _seed_legacy(session, user, user)
    grown = client.get("/api/v1/workspace/graph", headers=auth).json()
    titles = {node["title"]: node["concept_id"] for node in grown["nodes"]}
    target = titles["Dinosaurs"]
    other = Graph(slug="leftover", title="Leftover")
    session.add(other)
    session.commit()
    session.add(
        Edge(
            graph_id=other.id,
            from_concept_id=target,
            to_concept_id=titles["Birds"],
            type="related",
        )
    )
    session.commit()

    removed = client.delete(f"/api/v1/graph/nodes/{target}", headers=auth)
    assert removed.status_code == 200
    assert removed.json()["removed_edges"] >= 1
    after = client.get("/api/v1/workspace/graph", headers=auth).json()
    assert "Dinosaurs" not in {node["title"] for node in after["nodes"]}
    assert session.get(Concept, target) is None


def test_delete_extend_removes_the_nodes_and_edges_it_added(client, auth, other_auth, session, user, other_user):
    _seed_legacy(session, user, other_user)
    grown = client.get("/api/v1/workspace/graph", headers=auth).json()
    dinosaurs = next(item for item in grown["extend_requests"] if item["instruction"] == "Dinosaurs")
    removed = client.delete(f"/api/v1/graph/extend/{dinosaurs['id']}", headers=auth)
    assert removed.status_code == 200
    assert removed.json()["removed_nodes"] >= 1
    body = client.get("/api/v1/workspace/graph", headers=other_auth).json()
    titles = {node["title"] for node in body["nodes"]}
    assert "Dinosaurs" not in titles
    assert "Life sciences" not in titles
    assert "Birds" in titles
    assert all(item["instruction"] != "Dinosaurs" for item in body["extend_requests"])
    assert any(item["instruction"] == "Birds" for item in body["extend_requests"])
    dinosaur_ids = {node["concept_id"] for node in grown["nodes"] if node["title"] in {"Dinosaurs", "Life sciences"}}
    assert all(edge["from_concept_id"] not in dinosaur_ids and edge["to_concept_id"] not in dinosaur_ids for edge in body["edges"])
    missing = client.delete(f"/api/v1/graph/extend/{dinosaurs['id']}", headers=auth)
    assert missing.status_code == 404
    assert client.delete(f"/api/v1/graph/extend/{dinosaurs['id']}").status_code == 401


def _seed_legacy(session, user, other) -> None:
    """Concept rows that used to come from an extend, kept so deletion still has something to remove."""
    graph = shared_graph(session)
    dinosaurs_request = ExtendRequest(
        user_id=user.id,
        graph_id=graph.id,
        instruction="Dinosaurs",
        status="succeeded",
    )
    session.add(dinosaurs_request)
    session.flush()
    life = Concept(
        origin_graph_id=graph.id,
        title="Life sciences",
        summary="",
        explanation="Covers the range of life sciences.",
        level=1,
        canonical_key="life-sciences",
        extend_request_id=dinosaurs_request.id,
    )
    dinosaurs = Concept(
        origin_graph_id=graph.id,
        title="Dinosaurs",
        summary="",
        explanation="Covers the range of dinosaurs.",
        level=2,
        canonical_key="dinosaurs",
        extend_request_id=dinosaurs_request.id,
    )
    session.add(life)
    session.add(dinosaurs)
    session.flush()
    birds_request = ExtendRequest(
        user_id=other.id,
        graph_id=graph.id,
        parent_concept_id=dinosaurs.id,
        instruction="Birds",
        status="succeeded",
    )
    session.add(birds_request)
    session.flush()
    birds = Concept(
        origin_graph_id=graph.id,
        title="Birds",
        summary="",
        explanation="Covers the range of birds.",
        level=3,
        canonical_key="birds",
        extend_request_id=birds_request.id,
    )
    session.add(birds)
    session.flush()
    session.add(
        Edge(
            graph_id=graph.id,
            from_concept_id=life.id,
            to_concept_id=dinosaurs.id,
            type="contains",
            is_primary_parent=True,
            extend_request_id=dinosaurs_request.id,
        )
    )
    session.add(
        Edge(
            graph_id=graph.id,
            from_concept_id=dinosaurs.id,
            to_concept_id=birds.id,
            type="contains",
            is_primary_parent=True,
            extend_request_id=birds_request.id,
        )
    )
    session.commit()


def _reachable(root: str, edges: list[dict]) -> set[str]:
    children: dict[str, list[str]] = {}
    for edge in edges:
        if edge["type"] != "contains":
            continue
        children.setdefault(edge["from_concept_id"], []).append(edge["to_concept_id"])
    seen = {root}
    stack = [root]
    while stack:
        node = stack.pop()
        for child in children.get(node, []):
            if child not in seen:
                seen.add(child)
                stack.append(child)
    return seen
