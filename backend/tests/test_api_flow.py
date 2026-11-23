from app.features.accounts.firebase_auth import verify_firebase_id_token


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


def test_openapi_is_auth_and_knowledge_graph(client):
    paths = client.get("/openapi.json").json()["paths"]
    assert "/api/v1/auth/firebase" in paths
    assert "/api/v1/me" in paths
    assert "/api/v1/knowledge/focus" in paths
    assert "/api/v1/knowledge/graph/{focus_id}" in paths
    assert "/api/v1/me/reviews/due" in paths
    assert "/api/v1/me/reviews/distribution" in paths
    assert "/api/v1/me/reviews/submit" in paths
    assert "/api/v1/admin/cron-runs/preview" in paths
    assert "/api/v1/admin/cron-runs/run" in paths
    assert "/api/v1/workspace/graph" not in paths
    assert "/api/v1/graph/extend" not in paths
    assert "/api/v1/graph/nodes/{concept_id}" not in paths
    assert "/api/v1/admin/cron-runs/latest" not in paths
    assert "/api/v1/goals" not in paths
    assert "/api/v1/mastery/overview" not in paths
