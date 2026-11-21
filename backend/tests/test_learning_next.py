"""Learning track: next atomic pack picker."""

import random

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
        f"/api/v1/me/learning-next?seed_node_id={node.id}&opening=true",
        headers=auth,
    )
    assert response.status_code == 200
    body = response.json()
    assert body["status"] == "generate"
    assert body["node_id"] == str(node.id)
    assert body["title"] == "Empty"


def test_learning_next_returns_seed_pack(client, auth, session, user):
    seed = KnowledgeNode(
        name="Seed",
        name_key="seed",
        description="x",
        image_url="/knowledge/nodes/placeholder/image/file",
        image_bytes=b"fake-png",
    )
    session.add(seed)
    session.flush()
    seed.image_url = f"/knowledge/nodes/{seed.id}/image/file"
    _add_pack(session, seed.id)
    session.commit()

    response = client.get(
        f"/api/v1/me/learning-next?seed_node_id={seed.id}&opening=true",
        headers=auth,
    )
    assert response.status_code == 200
    body = response.json()
    assert body["status"] == "ready"
    assert body["node_id"] == str(seed.id)
    assert body["pack_index"] == 1
    assert body["pack"]["pack_index"] == 1
    assert body["image_url"] == f"/knowledge/nodes/{seed.id}/image/file"
    assert body["image_thumb_url"] == f"/knowledge/nodes/{seed.id}/image/file?variant=thumb"
    kinds = {bit["kind"] for bit in body["pack"]["bits"]}
    assert "learn" in kinds
    assert kinds & {"check1", "check2", "check3"}


def test_learning_next_opening_replays_learned_on_focus(session, user):
    seed = KnowledgeNode(name="Done", name_key="done-open", description="x")
    child = KnowledgeNode(name="Kid", name_key="kid-open", description="x")
    session.add(seed)
    session.add(child)
    session.flush()
    session.add(KnowledgeEdge(from_id=seed.id, relation="child", to_id=child.id))
    _add_pack(session, seed.id, pack_index=1)
    _add_pack(session, child.id, pack_index=1)
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

    result = learning_next(
        session, user=user, seed_node_id=seed.id, opening=True, rng=random.Random(0)
    )
    assert result["status"] == "ready"
    assert result["node_id"] == str(seed.id)
    assert result["pack_index"] == 1


def test_learning_next_exclude_can_land_on_child(session, user, monkeypatch):
    seed = KnowledgeNode(name="Seed", name_key="seed-ex", description="x")
    child = KnowledgeNode(name="Child", name_key="child-ex", description="x")
    session.add(seed)
    session.add(child)
    session.flush()
    session.add(KnowledgeEdge(from_id=seed.id, relation="child", to_id=child.id))
    _add_pack(session, seed.id, pack_index=1)
    _add_pack(session, child.id, pack_index=1)
    session.commit()

    from app.core.config import get_settings

    settings = get_settings()
    monkeypatch.setattr(settings, "learn_track_p_focus", 0.0)
    monkeypatch.setattr(settings, "learn_track_p_child", 1.0)
    monkeypatch.setattr(settings, "learn_track_p_other", 0.0)

    result = learning_next(
        session,
        user=user,
        seed_node_id=seed.id,
        exclude_node_id=seed.id,
        exclude_pack_index=1,
        rng=random.Random(1),
    )
    assert result["status"] == "ready"
    assert result["node_id"] == str(child.id)
    assert result["pack_index"] == 1


def test_learning_next_dice_generate_for_picked_tile(session, user, monkeypatch):
    seed = KnowledgeNode(name="Focus", name_key="focus-gen", description="x")
    child = KnowledgeNode(name="EmptyKid", name_key="empty-kid", description="x")
    session.add(seed)
    session.add(child)
    session.flush()
    session.add(KnowledgeEdge(from_id=seed.id, relation="child", to_id=child.id))
    _add_pack(session, seed.id, pack_index=1)
    session.commit()

    from app.core.config import get_settings

    settings = get_settings()
    monkeypatch.setattr(settings, "learn_track_p_focus", 0.0)
    monkeypatch.setattr(settings, "learn_track_p_child", 1.0)
    monkeypatch.setattr(settings, "learn_track_p_other", 0.0)

    result = learning_next(
        session,
        user=user,
        seed_node_id=seed.id,
        exclude_node_id=seed.id,
        exclude_pack_index=1,
        rng=random.Random(2),
    )
    assert result["status"] == "generate"
    assert result["node_id"] == str(child.id)


def test_learning_next_opening_prefers_focus_pack(session, user):
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

    result = learning_next(
        session, user=user, seed_node_id=seed.id, opening=True, rng=random.Random(3)
    )
    assert result["status"] == "ready"
    assert result["node_id"] == str(seed.id)
