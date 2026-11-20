"""Learning track: next atomic pack picker."""

import random

from app.core.config import get_settings
from app.features.content.models import KnowledgeBit
from app.features.knowledge_graph.node_models import KnowledgeEdge, KnowledgeNode
from app.features.learning.service import learning_next
from app.features.user_events.service import record_events


def _add_pack(session, node_id, *, pack_index=1):
    bits = [
        ("learn", 0, {"title": f"Pack {pack_index}", "markdown": f"Learn {pack_index}."}),
        (
            "check1",
            1,
            {
                "type": "mc",
                "prompt": "Q?",
                "choices": ["a", "b", "c", "d"],
                "answer_index": 0,
            },
        ),
        (
            "check2",
            2,
            {"type": "true_false", "prompt": "T?", "answer": True},
        ),
        (
            "check3",
            3,
            {"type": "cloze", "prompt": "Fill ___", "answers": ["x"]},
        ),
    ]
    for kind, position, body in bits:
        session.add(
            KnowledgeBit(
                node_id=node_id,
                pack_index=pack_index,
                kind=kind,
                band="default",
                recipe_version=1,
                position=position,
                body=body,
            )
        )


def test_learning_next_generate_when_no_packs(client, auth, session, user):
    node = KnowledgeNode(name="Empty", name_key="empty", description="x")
    session.add(node)
    session.commit()

    response = client.get(
        f"/api/v1/me/learning-next?seed_node_id={node.id}",
        headers=auth,
    )
    assert response.status_code == 200
    body = response.json()
    assert body["status"] == "generate"
    assert body["node_id"] == str(node.id)
    assert body["title"] == "Empty"


def test_learning_next_returns_seed_pack(client, auth, session, user):
    seed = KnowledgeNode(name="Seed", name_key="seed", description="x")
    session.add(seed)
    session.flush()
    _add_pack(session, seed.id)
    session.commit()

    response = client.get(
        f"/api/v1/me/learning-next?seed_node_id={seed.id}",
        headers=auth,
    )
    assert response.status_code == 200
    body = response.json()
    assert body["status"] == "ready"
    assert body["node_id"] == str(seed.id)
    assert body["pack_index"] == 1
    assert body["pack"]["pack_index"] == 1
    kinds = {bit["kind"] for bit in body["pack"]["bits"]}
    assert "learn" in kinds
    assert kinds & {"check1", "check2", "check3"}


def test_learning_next_skips_completed_atomic_pack(session, user):
    seed = KnowledgeNode(name="Done", name_key="done", description="x")
    neighbor = KnowledgeNode(name="Next", name_key="next", description="x")
    session.add(seed)
    session.add(neighbor)
    session.flush()
    session.add(KnowledgeEdge(from_id=seed.id, relation="child", to_id=neighbor.id))
    session.add(KnowledgeEdge(from_id=neighbor.id, relation="parent", to_id=seed.id))
    _add_pack(session, seed.id, pack_index=1)
    _add_pack(session, neighbor.id, pack_index=1)
    record_events(
        session,
        user=user,
        items=[
            {"node_id": str(seed.id), "kind": "learn", "payload": {"pack_index": 1}},
            {
                "node_id": str(seed.id),
                "kind": "check2",
                "payload": {"pack_index": 1, "correct": True, "answer_bool": True},
            },
        ],
    )
    session.commit()

    # Force explore away from empty seed by making exploit never stick
    # (seed has no eligible packs anyway).
    settings = get_settings().model_copy(update={"learn_track_exploit_p": 1.0})
    result = learning_next(
        session,
        user=user,
        seed_node_id=seed.id,
        settings=settings,
        rng=random.Random(0),
    )
    assert result["status"] == "ready"
    assert result["node_id"] == str(neighbor.id)
    assert result["pack_index"] == 1


def test_learning_next_exploit_prefers_seed(session, user):
    seed = KnowledgeNode(name="Focus", name_key="focus-learn", description="x")
    neighbor = KnowledgeNode(name="Side", name_key="side-learn", description="x")
    session.add(seed)
    session.add(neighbor)
    session.flush()
    session.add(KnowledgeEdge(from_id=seed.id, relation="sibling", to_id=neighbor.id))
    session.add(KnowledgeEdge(from_id=neighbor.id, relation="sibling", to_id=seed.id))
    _add_pack(session, seed.id)
    _add_pack(session, neighbor.id)
    session.commit()

    settings = get_settings().model_copy(update={"learn_track_exploit_p": 1.0})
    result = learning_next(
        session,
        user=user,
        seed_node_id=seed.id,
        settings=settings,
        rng=random.Random(1),
    )
    assert result["status"] == "ready"
    assert result["node_id"] == str(seed.id)
