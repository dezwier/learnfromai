"""Shared learn / example / check packs content jobs."""

from sqlmodel import func, select

from app.features.content.models import KnowledgeBit
from app.features.knowledge_graph.node_models import KnowledgeNode
from app.features.platform.content_llm import build_content_prompt, normalize_bits
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


def _kinds(pack: dict) -> set[str]:
    return {bit["kind"] for bit in pack["bits"]}


def test_content_get_never_enqueues(client, auth, session):
    node = KnowledgeNode(name="Attention", name_key="attention", description="Weighting context.")
    session.add(node)
    session.commit()

    response = client.get(f"/api/v1/knowledge/nodes/{node.id}/content", headers=auth)
    assert response.status_code == 200
    body = response.json()
    assert body["incomplete"] is True
    assert body["pack_count"] == 0
    assert body["packs"] == []
    assert body["completed_packs"] == []
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
    assert queued.json()["pack_index"] == 1

    job = _run_queued(session)
    assert job is not None
    assert job.state == "succeeded"

    ready = client.get(f"/api/v1/knowledge/nodes/{node.id}/content", headers=auth)
    assert ready.status_code == 200
    body = ready.json()
    assert body["incomplete"] is False
    assert body["pack_count"] == 1
    assert len(body["packs"]) == 1
    pack = body["packs"][0]
    assert pack["pack_index"] == 1
    assert pack["incomplete"] is False
    assert _kinds(pack) == {"learn", "check1", "check2", "check3"}
    for kind in ("check1", "check2", "check3"):
        check = next(bit for bit in pack["bits"] if bit["kind"] == kind)
        assert check["body"]["type"] == "mc"
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
                pack_index=1,
                kind="learn",
                position=0,
                body={"title": "What is Gradient?", "markdown": "A gradient points uphill."},
            ),
            KnowledgeBit(
                node_id=node.id,
                pack_index=1,
                kind="example",
                position=1,
                body={"title": "Gradient in practice", "markdown": "Follow the slope on a hill."},
            ),
            KnowledgeBit(
                node_id=node.id,
                pack_index=1,
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
    pack = before.json()["packs"][0]
    assert _kinds(pack) == {"learn", "example", "check1"}

    queued = client.post(
        f"/api/v1/knowledge/nodes/{node.id}/content",
        headers=auth,
        json={"expand": True},
    )
    assert queued.status_code == 202
    job = session.get(GenerationJob, queued.json()["job_id"])
    assert job is not None
    assert job.payload.get("missing_kinds") == ["check2", "check3"]
    assert job.payload.get("pack_index") == 1

    done = _run_queued(session)
    assert done is not None
    assert done.state == "succeeded"

    ready = client.get(f"/api/v1/knowledge/nodes/{node.id}/content", headers=auth)
    assert ready.status_code == 200
    body = ready.json()
    assert body["incomplete"] is False
    pack = body["packs"][0]
    assert {"learn", "check1", "check2", "check3"} <= _kinds(pack)
    check1 = next(bit for bit in pack["bits"] if bit["kind"] == "check1")
    assert check1["body"]["question"] == "Which fits Gradient?"


def test_content_new_pack_after_complete(client, auth, session):
    node = KnowledgeNode(name="Entropy", name_key="entropy", description="Uncertainty measure.")
    session.add(node)
    session.commit()

    first = client.post(
        f"/api/v1/knowledge/nodes/{node.id}/content",
        headers=auth,
        json={"expand": True},
    )
    assert first.status_code == 202
    _run_queued(session)

    second = client.post(
        f"/api/v1/knowledge/nodes/{node.id}/content",
        headers=auth,
        json={"expand": True, "new_pack": True},
    )
    assert second.status_code == 202
    assert second.json()["pack_index"] == 2
    job = _run_queued(session)
    assert job is not None
    assert job.state == "succeeded"

    ready = client.get(f"/api/v1/knowledge/nodes/{node.id}/content", headers=auth)
    body = ready.json()
    assert body["pack_count"] == 2
    assert body["incomplete"] is False
    types = {
        bit["body"]["type"]
        for pack in body["packs"]
        if pack["pack_index"] == 2
        for bit in pack["bits"]
        if bit["kind"].startswith("check")
    }
    assert "true_false" in types
    assert "cloze" in types


def test_content_reports_completed_packs_for_user(client, auth, session):
    node = KnowledgeNode(name="Dropout", name_key="dropout", description="Regularization.")
    session.add(node)
    session.commit()

    first = client.post(
        f"/api/v1/knowledge/nodes/{node.id}/content",
        headers=auth,
        json={"expand": True},
    )
    assert first.status_code == 202
    _run_queued(session)

    before = client.get(f"/api/v1/knowledge/nodes/{node.id}/content", headers=auth)
    assert before.json()["completed_packs"] == []

    # Atomic completion: learn + any one check is enough.
    client.post(
        "/api/v1/me/events",
        headers=auth,
        json={
            "events": [
                {"node_id": str(node.id), "kind": "learn", "payload": {"pack_index": 1}},
                {
                    "node_id": str(node.id),
                    "kind": "check1",
                    "payload": {"pack_index": 1, "correct": True, "choice_index": 0},
                },
            ]
        },
    )
    after = client.get(f"/api/v1/knowledge/nodes/{node.id}/content", headers=auth)
    assert after.json()["completed_packs"] == [1]


def test_content_new_pack_rejected_while_incomplete(client, auth, session):
    node = KnowledgeNode(name="Bias", name_key="bias", description="Systematic error.")
    session.add(node)
    session.flush()
    session.add(
        KnowledgeBit(
            node_id=node.id,
            pack_index=1,
            kind="learn",
            position=0,
            body={"title": "Bias", "markdown": "A systematic error."},
        )
    )
    session.commit()

    response = client.post(
        f"/api/v1/knowledge/nodes/{node.id}/content",
        headers=auth,
        json={"expand": True, "new_pack": True},
    )
    assert response.status_code == 422


def test_normalize_bits_typed_checks():
    normalized = normalize_bits(
        {
            "learn": {"title": "T", "markdown": "Body"},
            "check1": {
                "type": "mc",
                "question": "Q?",
                "choices": ["A", "B", "C", "D"],
                "answer_index": 2,
                "explanation": "C",
            },
            "check2": {
                "type": "true_false",
                "statement": "Softmax outputs sum to 1.",
                "answer": True,
                "explanation": "Yes.",
            },
            "check3": {
                "type": "cloze",
                "prompt": "Outputs are ___.",
                "answer": "probabilities",
                "aliases": ["probs"],
                "explanation": "Probabilities.",
            },
        }
    )
    assert normalized["learn"]["markdown"] == "Body"
    assert normalized["check1"]["type"] == "mc"
    assert normalized["check2"]["type"] == "true_false"
    assert normalized["check2"]["answer"] is True
    assert normalized["check3"]["type"] == "cloze"
    assert normalized["check3"]["aliases"] == ["probs"]


def test_normalize_cloze_rejects_multi_word_answer():
    import pytest

    with pytest.raises(ValueError, match="single word or number"):
        normalize_bits(
            {
                "learn": {"title": "T", "markdown": "Body"},
                "check1": {
                    "type": "mc",
                    "question": "Q?",
                    "choices": ["A", "B", "C", "D"],
                    "answer_index": 0,
                },
                "check2": {
                    "type": "true_false",
                    "statement": "True claim.",
                    "answer": True,
                },
                "check3": {
                    "type": "cloze",
                    "prompt": "Fill ___.",
                    "answer": "two words",
                },
            }
        )


def test_build_content_prompt_includes_existing_packs_and_neighbors():
    prompt = build_content_prompt(
        "Softmax",
        "Normalize scores",
        ["Attention", "Logits"],
        kinds=["learn", "check1", "check2", "check3"],
        existing_packs=[
            {
                "pack_index": 1,
                "title": "What is Softmax?",
                "learn_snippet": "Softmax maps scores to probs.",
                "check_stems": ["Which statement best fits Softmax?"],
            }
        ],
        pack_index=2,
    )
    assert "atomic learning" in prompt
    assert "interesting learning bit" in prompt
    assert "short (a few words" in prompt
    assert "What is Softmax?" in prompt
    assert "Attention" in prompt
    assert "true_false" in prompt
    assert "cloze" in prompt
    assert '"pack_index": 2' in prompt
    assert "Do not overlap other atomic learnings" in prompt
    assert "Do not teach neighboring topics" in prompt
    assert "Never mention neighbors, other learnings" in prompt
    assert "worth knowing" in prompt
    assert "genuinely useful" in prompt
    assert "exactly one word or one number" in prompt
