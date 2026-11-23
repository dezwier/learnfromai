"""Ranking affinity, job scores, and daily cron enqueue."""

import pytest

from app.core.config import get_settings
from app.features.content.models import KnowledgeBit
from app.features.knowledge_graph.node_models import KnowledgeEdge, KnowledgeNode
from app.features.platform.models import GenerationJob
from app.features.ranking.affinity import recency, score_user_tiles
from app.features.ranking.cron_run import cron_run_payload, run_daily_cron
from app.features.ranking.job_scores import learn_job_scores, neighbor_job_scores
from app.features.user_events.service import record_events, record_focus


def test_recency_linear_span():
    assert recency(0, span_days=30) == pytest.approx(1.0)
    assert recency(15, span_days=30) == pytest.approx(0.75, abs=1e-6)
    assert recency(30, span_days=30) == pytest.approx(0.5, abs=1e-6)
    assert recency(60, span_days=30) == pytest.approx(0.5, abs=1e-6)


def test_neighbor_and_learn_scores_prefer_deficit(session, user):
    rich = KnowledgeNode(name="Rich", name_key="rich", description="x")
    sparse = KnowledgeNode(name="Sparse", name_key="sparse", description="x")
    session.add(rich)
    session.add(sparse)
    session.flush()
    # Give Rich many neighbors so its fill factor is lower.
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
    assert neighbors["Sparse"]["fill_factor"] > neighbors["Rich"]["fill_factor"]
    assert neighbors["Sparse"]["score"] > neighbors["Rich"]["score"]

    learns = {row["name"]: row for row in learn_job_scores(session)}
    assert learns["Sparse"]["pack_count"] == 0
    assert learns["Rich"]["pack_count"] == 1
    assert learns["Sparse"]["fill_factor"] > learns["Rich"]["fill_factor"]
    assert learns["Sparse"]["score"] > learns["Rich"]["score"]


def test_learn_scores_prefer_fewer_packs(session, user):
    """Fewer packs → higher fill term → higher learn score when affinity is equal."""
    empty = KnowledgeNode(name="Empty", name_key="empty", description="x")
    one_pack = KnowledgeNode(name="OnePack", name_key="one-pack", description="x")
    session.add(empty)
    session.add(one_pack)
    session.flush()
    session.add(
        KnowledgeBit(
            node_id=one_pack.id,
            kind="learn",
            pack_index=1,
            band="default",
            recipe_version=1,
            position=0,
            body={"title": "t", "markdown": "m"},
        )
    )
    record_focus(session, user=user, node_id=empty.id)
    record_focus(session, user=user, node_id=one_pack.id)
    record_events(
        session,
        user=user,
        items=[
            {"node_id": str(empty.id), "kind": "open", "payload": {"source": "graph"}},
            {"node_id": str(one_pack.id), "kind": "open", "payload": {"source": "graph"}},
        ],
    )
    session.commit()

    learns = {row["name"]: row for row in learn_job_scores(session)}
    assert learns["Empty"]["pack_count"] == 0
    assert learns["OnePack"]["pack_count"] == 1
    assert learns["Empty"]["fill_factor"] == pytest.approx(1.0)
    assert learns["OnePack"]["fill_factor"] == pytest.approx(19 / 20)
    assert learns["Empty"]["score"] > learns["OnePack"]["score"]


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
    record_events(
        session,
        user=user,
        items=[{"node_id": str(focus.id), "kind": "open", "payload": {"source": "graph"}}],
    )
    session.commit()

    ranked = neighbor_job_scores(session, settings=settings)
    assert all(row["name"] != "Full" for row in ranked)


def test_admin_cron_preview_and_run_now(client, auth, session, user):
    blocked = client.get("/api/v1/admin/cron-runs/preview", headers=auth)
    assert blocked.status_code == 403
    blocked_run = client.post("/api/v1/admin/cron-runs/run", headers=auth)
    assert blocked_run.status_code == 403

    user.is_admin = True
    session.add(user)
    session.commit()

    # Seed a tile so the cron has something to rank.
    node = KnowledgeNode(name="CronNow", name_key="cron-now", description="x")
    session.add(node)
    session.flush()
    record_focus(session, user=user, node_id=node.id)
    record_events(
        session,
        user=user,
        items=[{"node_id": str(node.id), "kind": "open", "payload": {"source": "graph"}}],
    )
    session.commit()

    preview = client.get("/api/v1/admin/cron-runs/preview", headers=auth)
    assert preview.status_code == 200
    preview_body = preview.json()
    assert "neighbor_jobs" in preview_body
    assert "learn_jobs" in preview_body
    assert preview_body["limits"]["desired_neighbors"] == 16
    assert preview_body["limits"]["desired_packs"] == 20
    assert any(row["name"] == "CronNow" for row in preview_body["neighbor_jobs"])
    cron_now = next(row for row in preview_body["neighbor_jobs"] if row["name"] == "CronNow")
    assert "tile_affinity" in cron_now
    assert "fill_term" in cron_now
    assert "score" in cron_now

    response = client.post("/api/v1/admin/cron-runs/run", headers=auth)
    assert response.status_code == 200
    body = response.json()
    assert body["run"]["status"] == "succeeded"
    assert isinstance(body["run"]["neighbor_jobs"], list)
    assert isinstance(body["run"]["learn_jobs"], list)
    assert "preview" in body
    assert isinstance(body["preview"]["neighbor_jobs"], list)

    # Admin Run now attaches watchers so jobs show in the progress float.
    watched = client.get("/api/v1/jobs?state=queued,running", headers=auth)
    assert watched.status_code == 200
    watched_jobs = watched.json()["jobs"]
    assert any(j.get("title") == "CronNow" for j in watched_jobs)

    neighbors_only = client.post(
        "/api/v1/admin/cron-runs/run",
        headers=auth,
        json={"queues": ["neighbors"]},
    )
    assert neighbors_only.status_code == 200
    neighbors_body = neighbors_only.json()["run"]
    assert neighbors_body["status"] == "succeeded"
    assert isinstance(neighbors_body["neighbor_jobs"], list)
    assert neighbors_body["learn_jobs"] == []
    assert neighbors_body["weights_snapshot"].get("queues") == ["neighbors"]

    learns_only = client.post(
        "/api/v1/admin/cron-runs/run",
        headers=auth,
        json={"queues": ["learns"]},
    )
    assert learns_only.status_code == 200
    learns_body = learns_only.json()["run"]
    assert learns_body["status"] == "succeeded"
    assert learns_body["neighbor_jobs"] == []
    assert isinstance(learns_body["learn_jobs"], list)
    assert learns_body["weights_snapshot"].get("queues") == ["learns"]


def test_admin_fill_weights_update_ranking(client, auth, user, session):
    user.is_admin = True
    session.add(user)
    session.commit()

    rich = KnowledgeNode(name="WeightRich", name_key="weight-rich", description="x")
    sparse = KnowledgeNode(name="WeightSparse", name_key="weight-sparse", description="x")
    session.add(rich)
    session.add(sparse)
    session.flush()
    for i in range(8):
        n = KnowledgeNode(name=f"WN{i}", name_key=f"wn-{i}", description="x")
        session.add(n)
        session.flush()
        session.add(KnowledgeEdge(from_id=rich.id, relation="child", to_id=n.id))
        session.add(KnowledgeEdge(from_id=n.id, relation="parent", to_id=rich.id))
    # Sparse has higher affinity (more opens) but larger neighbor deficit.
    record_focus(session, user=user, node_id=rich.id)
    record_focus(session, user=user, node_id=sparse.id)
    record_events(
        session,
        user=user,
        items=[
            {"node_id": str(rich.id), "kind": "open", "payload": {"source": "graph"}},
            {"node_id": str(sparse.id), "kind": "open", "payload": {"source": "graph"}},
            {"node_id": str(sparse.id), "kind": "open", "payload": {"source": "graph"}},
            {"node_id": str(sparse.id), "kind": "open", "payload": {"source": "graph"}},
        ],
    )
    session.commit()

    preview = client.get("/api/v1/admin/cron-runs/preview", headers=auth)
    assert preview.status_code == 200
    assert preview.json()["limits"]["neighbor_w_fill"] == pytest.approx(1.0)
    assert preview.json()["limits"]["learn_w_fill"] == pytest.approx(1.0)

    # Zero neighbor fill → ranking follows affinity only (Sparse ahead).
    zero = client.patch(
        "/api/v1/admin/cron-runs/weights",
        headers=auth,
        json={"neighbor_w_fill": 0.0},
    )
    assert zero.status_code == 200
    zero_body = zero.json()
    assert zero_body["limits"]["neighbor_w_fill"] == pytest.approx(0.0)
    zero_names = [row["name"] for row in zero_body["neighbor_jobs"]]
    assert zero_names.index("WeightSparse") < zero_names.index("WeightRich")

    # Huge neighbor fill → deficit dominates (Sparse still has fewer neighbors).
    heavy = client.patch(
        "/api/v1/admin/cron-runs/weights",
        headers=auth,
        json={"neighbor_w_fill": 100.0, "learn_w_fill": 3.5},
    )
    assert heavy.status_code == 200
    heavy_body = heavy.json()
    assert heavy_body["limits"]["neighbor_w_fill"] == pytest.approx(100.0)
    assert heavy_body["limits"]["learn_w_fill"] == pytest.approx(3.5)
    heavy_by_name = {row["name"]: row for row in heavy_body["neighbor_jobs"]}
    assert heavy_by_name["WeightSparse"]["fill_term"] > heavy_by_name["WeightRich"]["fill_term"]
    assert heavy_by_name["WeightSparse"]["score"] > heavy_by_name["WeightRich"]["score"]

    forbidden = client.patch(
        "/api/v1/admin/cron-runs/weights",
        headers=auth,
        json={"neighbor_w_fill": -1},
    )
    assert forbidden.status_code == 422


def test_me_includes_is_admin(client, auth, user, session):
    response = client.get("/api/v1/me", headers=auth)
    assert response.status_code == 200
    assert response.json()["is_admin"] is False

    user.is_admin = True
    session.add(user)
    session.commit()
    response = client.get("/api/v1/me", headers=auth)
    assert response.json()["is_admin"] is True


def test_score_user_tiles_ignores_learn_events(session, user):
    node = KnowledgeNode(name="Packy", name_key="packy", description="x")
    session.add(node)
    session.flush()
    record_focus(session, user=user, node_id=node.id)
    record_events(
        session,
        user=user,
        items=[
            {"node_id": str(node.id), "kind": "open", "payload": {"source": "graph"}},
            {"node_id": str(node.id), "kind": "learn", "payload": {"pack_index": 1}},
            {
                "node_id": str(node.id),
                "kind": "check1",
                "payload": {"pack_index": 1, "correct": True, "choice_index": 0},
            },
        ],
    )
    session.commit()
    scored = score_user_tiles(session, user_id=user.id)
    assert scored[node.id]["learned"] is True
    # open-only interest_norm=1 + recency=1 ≈ 2 — learn/check/focus do not add
    assert scored[node.id]["affinity"] == pytest.approx(2.0, abs=0.1)
    assert scored[node.id]["open_count"] == 1


def test_score_user_tiles_ignores_focus_only(session, user):
    node = KnowledgeNode(name="Cold", name_key="cold", description="x")
    session.add(node)
    session.flush()
    record_focus(session, user=user, node_id=node.id)
    session.commit()
    assert score_user_tiles(session, user_id=user.id) == {}


def test_score_user_tiles_neighbor_spill(session, user):
    a = KnowledgeNode(name="A", name_key="a", description="x")
    b = KnowledgeNode(name="B", name_key="b", description="x")
    session.add(a)
    session.add(b)
    session.flush()
    session.add(KnowledgeEdge(from_id=a.id, relation="child", to_id=b.id))
    session.add(KnowledgeEdge(from_id=b.id, relation="parent", to_id=a.id))
    record_events(
        session,
        user=user,
        items=[
            {"node_id": str(a.id), "kind": "open", "payload": {"source": "graph"}},
            {"node_id": str(a.id), "kind": "open", "payload": {"source": "graph"}},
            {"node_id": str(b.id), "kind": "open", "payload": {"source": "graph"}},
        ],
    )
    session.commit()

    scored = score_user_tiles(session, user_id=user.id)
    # total=3 opens: A 2/3+1/3+1=2; B 1/3+2/3+1=2
    assert scored[a.id]["affinity"] == pytest.approx(2.0, abs=0.05)
    assert scored[b.id]["affinity"] == pytest.approx(2.0, abs=0.05)
    assert scored[a.id]["breakdown"]["neighbor"] == pytest.approx(1.0 / 3.0, abs=1e-4)
