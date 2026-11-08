from app.features.accounts.firebase_auth import verify_firebase_id_token
from app.workers.runner import process_until_idle


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


def test_extend_stays_pending_with_progress_until_the_worker_finishes(client, auth):
    created = client.post("/api/v1/graph/extend", headers=auth, json={"instruction": "Dinosaurs"})
    assert created.status_code == 202
    job_id = created.json()["job_id"]
    queued = client.get(f"/api/v1/jobs/{job_id}", headers=auth)
    assert queued.status_code == 200
    assert queued.json()["state"] == "queued"
    assert queued.json()["progress"]["message"] == "Waiting to generate"
    assert queued.json()["progress"]["fraction"] == 0.2
    workspace = client.get("/api/v1/workspace/graph", headers=auth).json()
    request = workspace["extend_requests"][0]
    assert request["status"] == "queued"
    assert request["progress_message"] == "Waiting to generate"
    assert request["progress_fraction"] == 0.2
    process_until_idle()
    finished = client.get(f"/api/v1/jobs/{job_id}", headers=auth).json()
    assert finished["state"] == "succeeded"
    assert finished["progress"]["stage"] == "done"
    done = client.get("/api/v1/workspace/graph", headers=auth).json()
    assert done["extend_requests"][0]["status"] == "succeeded"
    assert done["extend_requests"][0]["progress_message"] == "Generation finished"


def test_extend_merges_into_the_shared_graph(client, auth, other_auth):
    created = client.post("/api/v1/graph/extend", headers=auth, json={"instruction": "Dinosaurs"})
    assert created.status_code == 202
    job_id = created.json()["job_id"]
    assert client.get(f"/api/v1/jobs/{job_id}", headers=other_auth).status_code == 403
    process_until_idle()
    first = client.get("/api/v1/workspace/graph", headers=other_auth)
    assert first.status_code == 200
    body = first.json()
    titles = {node["title"]: node for node in body["nodes"]}
    assert set(titles) == {"Life sciences", "Dinosaurs"}
    dinosaur = titles["Dinosaurs"]
    assert titles["Life sciences"]["level"] == 1
    assert dinosaur["level"] == 2
    assert any(
        edge["from_concept_id"] == titles["Life sciences"]["concept_id"]
        and edge["to_concept_id"] == dinosaur["concept_id"]
        and edge["type"] == "contains"
        for edge in body["edges"]
    )
    assert "dinosaurs" in dinosaur["explanation"].lower()
    assert "foundations" not in dinosaur["title"].lower()
    assert body["extend_requests"][0]["instruction"] == "Dinosaurs"
    assert body["extend_requests"][0]["author"] == "Ada"
    assert body["extend_requests"][0]["status"] == "succeeded"
    assert "goal" not in body
    assert all("status" not in edge for edge in body["edges"])

    parent_id = dinosaur["concept_id"]
    child = client.post(
        "/api/v1/graph/extend",
        headers=other_auth,
        json={"instruction": "Birds", "parent_concept_id": parent_id},
    )
    assert child.status_code == 202
    process_until_idle()
    second = client.get("/api/v1/workspace/graph", headers=auth).json()
    by_title = {node["title"]: node["concept_id"] for node in second["nodes"]}
    assert "Birds" in by_title
    birds_node = next(node for node in second["nodes"] if node["title"] == "Birds")
    assert birds_node["level"] == 3
    assert "birds" in birds_node["explanation"].lower()
    assert any(
        edge["from_concept_id"] == parent_id and edge["to_concept_id"] == by_title["Birds"] and edge["type"] == "contains"
        for edge in second["edges"]
    )
    again = client.post("/api/v1/graph/extend", headers=auth, json={"instruction": "Dinosaurs"})
    assert again.status_code == 202
    process_until_idle()
    third = client.get("/api/v1/workspace/graph", headers=other_auth).json()
    assert len(third["nodes"]) == len(second["nodes"])
    assert [item["instruction"] for item in third["extend_requests"][:3]] == ["Dinosaurs", "Birds", "Dinosaurs"]
    assert {item["author"] for item in third["extend_requests"]} == {"Ada", "Grace"}


def test_openapi_is_auth_and_graph(client):
    paths = client.get("/openapi.json").json()["paths"]
    assert "/api/v1/auth/firebase" in paths
    assert "/api/v1/me" in paths
    assert "/api/v1/workspace/graph" in paths
    assert "/api/v1/graph/extend" in paths
    assert "/api/v1/graph/nodes/{concept_id}" in paths
    assert "delete" in paths["/api/v1/graph"]
    assert "/api/v1/goals" not in paths
    assert "/api/v1/reviews/due" not in paths
    assert "/api/v1/mastery/overview" not in paths


def test_delete_node_removes_its_edges(client, auth, other_auth):
    created = client.post("/api/v1/graph/extend", headers=auth, json={"instruction": "Dinosaurs"})
    assert created.status_code == 202
    process_until_idle()
    before = client.get("/api/v1/workspace/graph", headers=auth).json()
    titles = {node["title"]: node["concept_id"] for node in before["nodes"]}
    parent_id = titles["Dinosaurs"]
    child = client.post(
        "/api/v1/graph/extend",
        headers=other_auth,
        json={"instruction": "Birds", "parent_concept_id": parent_id},
    )
    assert child.status_code == 202
    process_until_idle()
    with_child = client.get("/api/v1/workspace/graph", headers=auth).json()
    child_titles = {node["title"]: node["concept_id"] for node in with_child["nodes"]}
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


def test_delete_node_removes_edges_recorded_on_another_graph(client, auth, session):
    from app.features.knowledge_graph.models import Concept, Edge, Graph

    created = client.post("/api/v1/graph/extend", headers=auth, json={"instruction": "Dinosaurs"})
    assert created.status_code == 202
    process_until_idle()
    body = client.get("/api/v1/workspace/graph", headers=auth).json()
    titles = {node["title"]: node["concept_id"] for node in body["nodes"]}
    child = client.post(
        "/api/v1/graph/extend",
        headers=auth,
        json={"instruction": "Birds", "parent_concept_id": titles["Dinosaurs"]},
    )
    assert child.status_code == 202
    process_until_idle()
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


def test_clear_graph_removes_every_node_and_edge(client, auth):
    created = client.post("/api/v1/graph/extend", headers=auth, json={"instruction": "Dinosaurs"})
    assert created.status_code == 202
    process_until_idle()
    removed = client.delete("/api/v1/graph", headers=auth)
    assert removed.status_code == 200
    assert removed.json()["removed_nodes"] >= 1
    body = client.get("/api/v1/workspace/graph", headers=auth).json()
    assert body["nodes"] == []
    assert body["edges"] == []
    assert body["extend_requests"][0]["instruction"] == "Dinosaurs"
    assert body["extend_requests"][0]["parent_concept_id"] is None
    assert client.delete("/api/v1/graph").status_code == 401


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
