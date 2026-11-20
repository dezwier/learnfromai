"""Ranking affinity, job scores, and daily cron enqueue."""

from datetime import timedelta

import pytest

from app.core.config import get_settings
from app.core.time import utcnow
from app.features.content.models import KnowledgeBit
from app.features.knowledge_graph.node_models import KnowledgeEdge, KnowledgeNode
from app.features.platform.models import GenerationJob
from app.features.ranking.affinity import recency, score_user_tiles
from app.features.ranking.cron_run import cron_run_payload, run_daily_cron
from app.features.ranking.job_scores import learn_job_scores, neighbor_job_scores
from app.features.ranking.models import CronRun
from app.features.user_events.service import record_events, record_focus


def test_recency_soft_decay():
    assert recency(0, half_life_days=14) == pytest.approx(1.0)
    assert recency(14, half_life_days=14) == pytest.approx(0.5, abs=1e-6)
    assert recency(28, half_life_days=14) == pytest.approx(0.25, abs=1e-6)
    assert recency(1000, half_life_days=14) > 0


def test_neighbor_and_learn_scores_penalize(session, user):
    rich = KnowledgeNode(name="Rich", name_key="rich", description="x")
    sparse = KnowledgeNode(name="Sparse", name_key="sparse", description="x")
    session.add(rich)
    session.add(sparse)
    session.flush()
    # Give Rich many neighbors so it is scored lower / skipped when at budget.
    for i in range(3):
        n = KnowledgeNode(name=f"N{i}", name_key=f"n-{i}", description="x")
        session.add(n)
        session.flush()
        session.add(KnowledgeEdge(from_id=rich.id, relation="child", to_id=n.id))
        session.add(KnowledgeEdge(from_id=n.id, relation="parent", to_id=rich.id))
    session.add(
        KnowledgeBit(
            node_id=rich.id,
            kind="learn",
            pack_index=1,
            band="default",
            recipe_version=1,
            position=0,
            body={"title": "t", "markdown": "m"},
        )
    )
    record_focus(session, user=user, node_id=rich.id)
    record_focus(session, user=user, node_id=sparse.id)
    record_events(
        session,
        user=user,
        items=[
            {"node_id": str(rich.id), "kind": "open", "payload": {"source": "graph"}},
            {"node_id": str(sparse.id), "kind": "open", "payload": {"source": "graph"}},
        ],
    )
    session.commit()

    neighbors = {row["name"]: row for row in neighbor_job_scores(session)}
    assert "Sparse" in neighbors
    assert "Rich" in neighbors
    assert neighbors["Sparse"]["score"] > neighbors["Rich"]["score"]

    learns = {row["name"]: row for row in learn_job_scores(session)}
    assert learns["Sparse"]["pack_count"] == 0
    assert learns["Rich"]["pack_count"] == 1
    assert learns["Sparse"]["score"] > learns["Rich"]["score"]


def test_cron_enqueues_and_persists(session, user):
    settings = get_settings().model_copy(
        update={"cron_neighbor_jobs_per_day": 2, "cron_learn_jobs_per_day": 2}
    )

    a = KnowledgeNode(name="Alpha", name_key="alpha", description="x")
    b = KnowledgeNode(name="Beta", name_key="beta", description="x")
    session.add(a)
    session.add(b)
    session.flush()
    record_focus(session, user=user, node_id=a.id)
    record_focus(session, user=user, node_id=b.id)
    record_events(
        session,
        user=user,
        items=[
            {"node_id": str(a.id), "kind": "open", "payload": {"source": "graph"}},
            {"node_id": str(b.id), "kind": "learn", "payload": {"pack_index": 1}},
        ],
    )
    session.commit()

    run = run_daily_cron(session, settings=settings)
    session.commit()

    assert run.status == "succeeded"
    assert len(run.neighbor_jobs) >= 1
    assert len(run.learn_jobs) >= 1
    from sqlmodel import select

    jobs = list(session.exec(select(GenerationJob)).all())
    types = {j.type for j in jobs}
    assert "expand_neighborhood" in types
    assert "expand_content" in types

    payload = cron_run_payload(session, run)
    assert payload["status"] == "succeeded"
    assert payload["neighbor_jobs"]


def test_cron_skips_complete_neighborhood(session, user):
    settings = get_settings().model_copy(
        update={"cron_neighbor_budget_total": 2, "cron_neighbor_jobs_per_day": 5}
    )

    focus = KnowledgeNode(name="Full", name_key="full", description="x")
    session.add(focus)
    session.flush()
    for i in range(2):
        n = KnowledgeNode(name=f"Child{i}", name_key=f"child-{i}", description="x")
        session.add(n)
        session.flush()
        session.add(KnowledgeEdge(from_id=focus.id, relation="child", to_id=n.id))
        session.add(KnowledgeEdge(from_id=n.id, relation="parent", to_id=focus.id))
    record_focus(session, user=user, node_id=focus.id)
    session.commit()

    ranked = neighbor_job_scores(session, settings=settings)
    assert all(row["name"] != "Full" for row in ranked)


def test_admin_cron_latest(client, auth, session, user):
    response = client.get("/api/v1/admin/cron-runs/latest", headers=auth)
    assert response.status_code == 403

    user.is_admin = True
    session.add(user)
    session.commit()

    # May already have runs from earlier tests in this session — still 200.
    listed = client.get("/api/v1/admin/cron-runs/latest", headers=auth)
    assert listed.status_code == 200
    assert "run" in listed.json()

    run = CronRun(
        status="succeeded",
        started_at=utcnow() + timedelta(minutes=1),
        finished_at=utcnow() + timedelta(minutes=1),
        neighbor_jobs=[{"node_id": "x", "name": "UniqueCronTile", "score": 1.0, "job_id": None}],
        learn_jobs=[],
        weights_snapshot={},
    )
    session.add(run)
    session.commit()

    latest = client.get("/api/v1/admin/cron-runs/latest", headers=auth)
    assert latest.status_code == 200
    body = latest.json()["run"]
    assert body["status"] == "succeeded"
    assert body["neighbor_jobs"][0]["name"] == "UniqueCronTile"


def test_me_includes_is_admin(client, auth, user, session):
    response = client.get("/api/v1/me", headers=auth)
    assert response.status_code == 200
    assert response.json()["is_admin"] is False

    user.is_admin = True
    session.add(user)
    session.commit()
    response = client.get("/api/v1/me", headers=auth)
    assert response.json()["is_admin"] is True


def test_score_user_tiles_uses_packs(session, user):
    node = KnowledgeNode(name="Packy", name_key="packy", description="x")
    session.add(node)
    session.flush()
    record_focus(session, user=user, node_id=node.id)
    record_events(
        session,
        user=user,
        items=[
            {"node_id": str(node.id), "kind": "learn", "payload": {"pack_index": 1}},
            {
                "node_id": str(node.id),
                "kind": "check1",
                "payload": {"pack_index": 1, "correct": True, "choice_index": 0},
            },
            {
                "node_id": str(node.id),
                "kind": "check2",
                "payload": {"pack_index": 1, "correct": True, "answer_bool": True},
            },
            {
                "node_id": str(node.id),
                "kind": "check3",
                "payload": {"pack_index": 1, "correct": True, "answer_text": "ok"},
            },
        ],
    )
    session.commit()
    scored = score_user_tiles(session, user_id=user.id)
    assert scored[node.id]["packs_done"] == 1
    # focus(1) + learned(3) + packs(1) + new(2) ≈ 7
    assert scored[node.id]["affinity"] == pytest.approx(7.0, abs=0.1)
