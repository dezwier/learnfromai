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


def test_extend_merges_into_the_shared_graph(client, auth, other_auth):
    created = client.post("/api/v1/graph/extend", headers=auth, json={"instruction": "Dinosaurs"})
    assert created.status_code == 202
    job_id = created.json()["job_id"]
    assert client.get(f"/api/v1/jobs/{job_id}", headers=other_auth).status_code == 403
    process_until_idle()
    first = client.get("/api/v1/workspace/graph", headers=other_auth)
    assert first.status_code == 200
    body = first.json()
    titles = {node["title"]: node["concept_id"] for node in body["nodes"]}
    assert "Dinosaurs" in titles
    assert "Foundations of Dinosaurs" in titles
    assert "Definitions in Dinosaurs" in titles
    assert _reachable(titles["Dinosaurs"], body["edges"]) == set(titles.values())
    assert sum(1 for edge in body["edges"] if edge["type"] == "prerequisite") == 1
    assert sum(1 for edge in body["edges"] if edge["type"] == "related") == 1
    assert body["extend_requests"][0]["instruction"] == "Dinosaurs"
    assert body["extend_requests"][0]["author"] == "Ada"
    assert body["extend_requests"][0]["status"] == "succeeded"
    assert "goal" not in body
    assert all("status" not in edge for edge in body["edges"])

    parent_id = titles["Dinosaurs"]
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
    assert "/api/v1/goals" not in paths
    assert "/api/v1/reviews/due" not in paths
    assert "/api/v1/mastery/overview" not in paths


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
