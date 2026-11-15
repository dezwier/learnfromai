"""Shared learn / example / check1–3 content jobs."""

from sqlmodel import func, select

from app.features.content.models import KnowledgeBit
from app.features.knowledge_graph.node_models import KnowledgeNode
from app.features.platform.jobs import claim_next
from app.features.platform.models import GenerationJob
from app.workers.handlers import handle


def _run_queued(session):
    claimed = claim_next(session)
    assert claimed is not None
    job, token = claimed
    handle(job.id, token)
    session.expire_all()
    return session.get(GenerationJob, job.id)


def test_content_get_never_enqueues(client, auth, session):
    node = KnowledgeNode(name="Attention", name_key="attention", description="Weighting context.")
    session.add(node)
    session.commit()

    response = client.get(f"/api/v1/knowledge/nodes/{node.id}/content", headers=auth)
    assert response.status_code == 200
    body = response.json()
    assert body["incomplete"] is True
    assert body["bits"] == []
    assert session.exec(select(func.count()).select_from(GenerationJob)).one() == 0


def test_content_expand_generates_five_bits(client, auth, session):
    node = KnowledgeNode(name="Attention", name_key="attention", description="Weighting context.")
    session.add(node)
    session.commit()

    queued = client.post(
        f"/api/v1/knowledge/nodes/{node.id}/content",
        headers=auth,
        json={"expand": True},
    )
    assert queued.status_code == 202
    assert queued.json()["job_id"]
    assert queued.json()["focus_node_id"] == str(node.id)

    job = _run_queued(session)
    assert job is not None
    assert job.state == "succeeded"

    ready = client.get(f"/api/v1/knowledge/nodes/{node.id}/content", headers=auth)
    assert ready.status_code == 200
    body = ready.json()
    assert body["incomplete"] is False
    kinds = {bit["kind"] for bit in body["bits"]}
    assert kinds == {"learn", "example", "check1", "check2", "check3"}
    for kind in ("check1", "check2", "check3"):
        check = next(bit for bit in body["bits"] if bit["kind"] == kind)
        assert len(check["body"]["choices"]) == 4
        assert check["body"]["answer_index"] in (0, 1, 2, 3)


def test_content_expand_coalesces_and_skips_when_complete(client, auth, other_auth, session):
    node = KnowledgeNode(name="Softmax", name_key="softmax", description="Normalize scores.")
    session.add(node)
    session.commit()

    first = client.post(
        f"/api/v1/knowledge/nodes/{node.id}/content",
        headers=auth,
        json={"expand": True},
    )
    second = client.post(
        f"/api/v1/knowledge/nodes/{node.id}/content",
        headers=other_auth,
        json={"expand": True},
    )
    assert first.status_code == 202
    assert second.status_code == 202
    assert first.json()["job_id"] == second.json()["job_id"]
    assert session.exec(select(func.count()).select_from(GenerationJob)).one() == 1

    _run_queued(session)
    again = client.post(
        f"/api/v1/knowledge/nodes/{node.id}/content",
        headers=auth,
        json={"expand": True},
    )
    assert again.status_code == 200
    assert again.json()["incomplete"] is False
    assert again.json().get("job_id") is None
    assert session.exec(select(func.count()).select_from(GenerationJob)).one() == 1


def test_content_backfills_missing_checks_for_legacy_recipe(client, auth, session):
    """Existing learn/example/check rows still enqueue only for missing check2/check3."""
    node = KnowledgeNode(name="Gradient", name_key="gradient", description="Direction of steepest ascent.")
    session.add(node)
    session.flush()
    session.add_all(
        [
            KnowledgeBit(
                node_id=node.id,
                kind="learn",
                position=0,
                body={"title": "What is Gradient?", "markdown": "A gradient points uphill."},
            ),
            KnowledgeBit(
                node_id=node.id,
                kind="example",
                position=1,
                body={"title": "Gradient in practice", "markdown": "Follow the slope on a hill."},
            ),
            KnowledgeBit(
                node_id=node.id,
                kind="check",
                position=2,
                body={
                    "question": "Which fits Gradient?",
                    "choices": ["A", "B", "C", "D"],
                    "answer_index": 0,
                    "explanation": "A",
                },
            ),
        ]
    )
    session.commit()

    before = client.get(f"/api/v1/knowledge/nodes/{node.id}/content", headers=auth)
    assert before.status_code == 200
    assert before.json()["incomplete"] is True
    kinds_before = {bit["kind"] for bit in before.json()["bits"]}
    assert kinds_before == {"learn", "example", "check1"}

    queued = client.post(
        f"/api/v1/knowledge/nodes/{node.id}/content",
        headers=auth,
        json={"expand": True},
    )
    assert queued.status_code == 202
    job = session.get(GenerationJob, queued.json()["job_id"])
    assert job is not None
    assert job.payload.get("missing_kinds") == ["check2", "check3"]

    done = _run_queued(session)
    assert done is not None
    assert done.state == "succeeded"

    ready = client.get(f"/api/v1/knowledge/nodes/{node.id}/content", headers=auth)
    assert ready.status_code == 200
    body = ready.json()
    assert body["incomplete"] is False
    kinds = {bit["kind"] for bit in body["bits"]}
    assert kinds == {"learn", "example", "check1", "check2", "check3"}
    # Legacy check row is exposed as check1 and kept (renamed or mapped).
    check1 = next(bit for bit in body["bits"] if bit["kind"] == "check1")
    assert check1["body"]["question"] == "Which fits Gradient?"
