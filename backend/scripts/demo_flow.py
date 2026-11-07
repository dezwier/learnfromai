"""Walk the Decision Trees journey with the fixture model. No paid LLM calls."""

from __future__ import annotations

from fastapi.testclient import TestClient
from sqlmodel import Session, select

from app.core.db import engine
from app.core.security import create_access_token
from app.features.accounts.models import User
from app.features.knowledge_graph.service import seed_decision_trees
from app.main import app
from app.model_registry import register_models
from app.workers.runner import process_until_idle


def main() -> None:
    register_models()
    with Session(engine, expire_on_commit=False) as session:
        graph = seed_decision_trees(session)
        user = session.exec(select(User).where(User.firebase_uid == "demo-learner")).first()
        if user is None:
            user = User(firebase_uid="demo-learner", email="demo@example.com", display_name="Demo", timezone="Europe/Brussels")
            session.add(user)
        session.commit()
        session.refresh(user)
        token = create_access_token(user.id)
        graph_id = str(graph.id)
    client = TestClient(app)
    headers = {"Authorization": f"Bearer {token}"}
    me = client.get("/api/v1/me", headers=headers).json()
    print("signed in", me["display_name"])
    goal = client.post(
        "/api/v1/goals",
        headers=headers,
        json={"topic": "Decision Trees", "purpose": "Build professional ML systems", "target_depth": "professional", "minutes_per_week": 180, "language": "en"},
    ).json()
    process_until_idle()
    print("goal", goal["goal_id"], "graph", graph_id)
    questions = client.post(f"/api/v1/goals/{goal['goal_id']}/diagnostic", headers=headers, json={}).json()["questions"]
    client.post(
        f"/api/v1/goals/{goal['goal_id']}/diagnostic",
        headers=headers,
        json={"answers": [{"objective_id": item["objective_id"], "response": "unknown"} for item in questions]},
    )
    recommendation = client.get(f"/api/v1/goals/{goal['goal_id']}/recommendation", headers=headers).json()
    print("next", recommendation["step"]["concept_title"], recommendation["step"]["rationale"])
    opened = client.post("/api/v1/learning-sessions", headers=headers, json={"goal_id": goal["goal_id"]}).json()
    pending = client.get(f"/api/v1/learning-sessions/{opened['session_id']}/next", headers=headers)
    if pending.status_code == 202:
        process_until_idle()
    activity = client.get(f"/api/v1/learning-sessions/{opened['session_id']}/next", headers=headers).json()["activity"]
    client.post(
        f"/api/v1/learning-sessions/{opened['session_id']}/attempts",
        headers={**headers, "Idempotency-Key": "demo-read"},
        json={"activity_id": activity["id"], "answer": {}},
    )
    pending = client.get(f"/api/v1/learning-sessions/{opened['session_id']}/next", headers=headers)
    if pending.status_code == 202:
        process_until_idle()
    question = client.get(f"/api/v1/learning-sessions/{opened['session_id']}/next", headers=headers).json()["activity"]
    graded = client.post(
        f"/api/v1/learning-sessions/{opened['session_id']}/attempts",
        headers={**headers, "Idempotency-Key": "demo-grade"},
        json={"activity_id": question["id"], "answer": {"text": question["body"].get("prompt", "")}},
    ).json()
    print("score", graded["feedback"]["score"], "trajectory", graded["trajectory_version"])
    tree = client.get(f"/api/v1/graphs/{graph_id}/tree", headers=headers).json()
    parent = tree["nodes"][0]["concept_id"]
    expansion = client.post(
        f"/api/v1/graphs/{graph_id}/expansions",
        headers=headers,
        json={
            "base_release_id": tree["release_id"],
            "parent_concept_id": parent,
            "instruction": "Expand information-theoretic splitting criteria",
            "max_depth": 2,
            "max_new_concepts": 12,
            "visibility": "private",
        },
    ).json()
    process_until_idle()
    job = client.get(f"/api/v1/jobs/{expansion['job_id']}", headers=headers).json()
    proposal_id = job["result"]["proposal_id"]
    preview = client.get(f"/api/v1/graphs/{graph_id}/migration-preview", headers=headers, params={"proposal_id": proposal_id, "goal_id": goal["goal_id"]}).json()
    print("preview", preview["impact"])
    accepted = client.post(f"/api/v1/graphs/{graph_id}/proposals/{proposal_id}/accept-private", headers=headers, params={"goal_id": goal["goal_id"]}).json()
    print("activated", accepted["status"], accepted["release_id"])


if __name__ == "__main__":
    main()
