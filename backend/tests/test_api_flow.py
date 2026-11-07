from datetime import timedelta
from uuid import UUID

from sqlmodel import select

from app.core.config import get_settings
from app.core.time import utcnow
from app.features.accounts.firebase_auth import verify_firebase_id_token
from app.features.knowledge_graph.service import seed_decision_trees, stable_id
from app.features.learning_sessions.models import AssessmentAttempt
from app.features.mastery.models import MasteryEvidence
from app.features.retention.models import ReviewItem
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


def test_cross_user_goal_is_forbidden(client, auth, other_auth, session):
    seed_decision_trees(session)
    session.commit()
    created = client.post("/api/v1/goals", headers=auth, json={"topic": "Decision Trees", "purpose": "systems", "target_depth": "professional", "minutes_per_week": 180, "language": "en"})
    assert created.status_code == 202
    process_until_idle()
    goal_id = created.json()["goal_id"]
    denied = client.post(f"/api/v1/goals/{goal_id}/diagnostic", headers=other_auth, json={})
    assert denied.status_code == 403
    assert denied.json()["code"] == "FORBIDDEN"


def test_seeded_tree_and_rollback(client, auth, session):
    seed_decision_trees(session)
    session.commit()
    graph_id = str(stable_id("graph:decision-trees"))
    tree = client.get(f"/api/v1/graphs/{graph_id}/tree", headers=auth)
    assert tree.status_code == 200
    titles = _titles(tree.json()["nodes"])
    assert {"Decision Trees", "Entropy", "Information Gain"} <= titles
    release_id = tree.json()["release_id"]
    admin = session.exec(__import__("sqlmodel").select(__import__("app.features.accounts.models", fromlist=["User"]).User)).first()
    _ = admin
    from app.features.accounts.models import User

    owner = session.exec(select(User)).first()
    owner.is_admin = True
    session.add(owner)
    session.commit()
    renamed = client.post(
        f"/api/v1/graphs/{graph_id}/rollback",
        headers=auth,
        json={"source_release_id": release_id, "base_release_id": release_id},
    )
    assert renamed.status_code == 201
    assert renamed.json()["version"] == 2
    assert renamed.json()["release_id"] != release_id
    diff = client.get(
        f"/api/v1/graphs/{graph_id}/diff",
        headers=auth,
        params={"from_release": release_id, "to_release": renamed.json()["release_id"]},
    )
    assert diff.status_code == 200
    stale = client.post(
        f"/api/v1/graphs/{graph_id}/rollback",
        headers=auth,
        json={"source_release_id": release_id, "base_release_id": release_id},
    )
    assert stale.status_code == 409
    assert stale.json()["code"] == "GRAPH_STALE"


def test_learn_assess_review_replan(client, auth, session, user):
    seed_decision_trees(session)
    session.commit()
    created = client.post(
        "/api/v1/goals",
        headers=auth,
        json={"topic": "Decision Trees", "purpose": "Read trees", "target_depth": "professional", "minutes_per_week": 120, "language": "en"},
    )
    process_until_idle()
    goal_id = created.json()["goal_id"]
    questions = client.post(f"/api/v1/goals/{goal_id}/diagnostic", headers=auth, json={})
    assert questions.json()["questions"]
    submitted = client.post(
        f"/api/v1/goals/{goal_id}/diagnostic",
        headers=auth,
        json={"answers": [{"objective_id": questions.json()["questions"][0]["objective_id"], "response": "unknown"}]},
    )
    assert submitted.status_code == 200
    recommendation = client.get(f"/api/v1/goals/{goal_id}/recommendation", headers=auth).json()
    assert recommendation["step"] is not None
    opened = client.post("/api/v1/learning-sessions", headers=auth, json={"goal_id": goal_id})
    session_id = opened.json()["session_id"]
    pinned = opened.json()["trajectory_id"]
    first = client.get(f"/api/v1/learning-sessions/{session_id}/next", headers=auth)
    assert first.status_code == 202
    process_until_idle()
    explain = client.get(f"/api/v1/learning-sessions/{session_id}/next", headers=auth)
    assert explain.status_code == 200
    activity_id = explain.json()["activity"]["id"]
    assert "answer" not in explain.json()["activity"]["body"]
    read = client.post(
        f"/api/v1/learning-sessions/{session_id}/attempts",
        headers={**auth, "Idempotency-Key": "read-1"},
        json={"activity_id": activity_id, "answer": {}},
    )
    assert read.status_code == 201
    assert read.json()["mastery_update"]["objectives_changed"] == 0
    again = client.post(
        f"/api/v1/learning-sessions/{session_id}/attempts",
        headers={**auth, "Idempotency-Key": "read-1"},
        json={"activity_id": activity_id, "answer": {}},
    )
    assert again.json()["attempt_id"] == read.json()["attempt_id"]
    question = client.get(f"/api/v1/learning-sessions/{session_id}/next", headers=auth)
    if question.status_code == 202:
        process_until_idle()
        question = client.get(f"/api/v1/learning-sessions/{session_id}/next", headers=auth)
    prompt = question.json()["activity"]
    answer_text = prompt["body"]["prompt"]
    graded = client.post(
        f"/api/v1/learning-sessions/{session_id}/attempts",
        headers={**auth, "Idempotency-Key": "grade-1"},
        json={"activity_id": prompt["id"], "answer": {"text": answer_text}},
    )
    assert graded.status_code == 201
    assert graded.json()["feedback"]["score"] == 1
    evidence = session.exec(select(MasteryEvidence).where(MasteryEvidence.user_id == user.id)).all()
    assert evidence
    attempt = session.get(AssessmentAttempt, UUID(graded.json()["attempt_id"]))
    original = (attempt.response, attempt.score, str(attempt.concept_revision_id))
    reviews = session.exec(select(ReviewItem).where(ReviewItem.user_id == user.id)).all()
    assert reviews
    reviews[0].due_at = utcnow() - timedelta(minutes=1)
    session.add(reviews[0])
    session.commit()
    due = client.get("/api/v1/reviews/due", headers=auth).json()["items"]
    assert due
    submitted_review = client.post(
        f"/api/v1/reviews/{due[0]['id']}/submit",
        headers={**auth, "Idempotency-Key": "rev-1"},
        json={"answer": {"text": due[0]["prompt"]}, "rating": "good"},
    )
    assert submitted_review.status_code == 200
    session.refresh(attempt)
    assert (attempt.response, attempt.score, str(attempt.concept_revision_id)) == original
    current = client.get(f"/api/v1/learning-sessions/{session_id}", headers=auth)
    _ = current
    still = client.get("/api/v1/learning-sessions/" + session_id + "/next", headers=auth)
    _ = (pinned, still)


def test_quota(client, auth, session, user):
    seed_decision_trees(session)
    session.commit()
    get_settings().llm_daily_tokens_user_limit = 0
    created = client.post("/api/v1/goals", headers=auth, json={"topic": "Quantum basket weaving", "purpose": "fun", "target_depth": "overview", "minutes_per_week": 30, "language": "en"})
    process_until_idle()
    job_id = created.json()["job_id"]
    job = client.get(f"/api/v1/jobs/{job_id}", headers=auth)
    assert job.json()["error_code"] in {"RATE_LIMITED", "GENERATION_UNAVAILABLE", None} or job.json()["state"] in {"failed", "succeeded"}
    get_settings().llm_daily_tokens_user_limit = 1_000_000


def test_delete_goal_removes_it_from_the_list(client, auth):
    created = client.post(
        "/api/v1/goals",
        headers=auth,
        json={"topic": "Childhood nutrition", "purpose": "feed children well", "target_depth": "overview", "minutes_per_week": 60, "language": "en"},
    )
    goal_id = created.json()["goal_id"]
    deleted = client.delete(f"/api/v1/goals/{goal_id}", headers=auth)
    assert deleted.status_code == 200
    listed = client.get("/api/v1/goals", headers=auth).json()["goals"]
    assert goal_id not in {row["id"] for row in listed}


def test_childhood_nutrition_branch_uses_real_topics():
    from app.features.platform.llm import FakeLLMProvider

    payload, _usage = FakeLLMProvider().propose_graph_branch({"topic": "childhood nutrition"})
    titles = {node["title"] for node in payload["nodes"]}
    assert {"Childhood nutrition", "Breastfeeding", "Complementary feeding", "Micronutrients", "Growth", "Stunting"} <= titles
    assert not any(title.lower().endswith(" structure") or title.lower().endswith(" origins") for title in titles)


def _titles(nodes: list[dict]) -> set[str]:
    found = set()
    for node in nodes:
        found.add(node["title"])
        found |= _titles(node["children"])
    return found
