"""Admin pack / quiz bit deletion."""

from sqlmodel import col, select

from app.features.content.models import KnowledgeBit
from app.features.knowledge_graph.node_models import KnowledgeNode
from app.features.reviews.models import UserPackReview
from app.features.user_events.models import UserTopicEvent
from app.features.user_events.service import record_events


def _seed_pack(session, node, *, pack_index: int = 1, checks=("check1", "check2", "check3")):
    session.add(
        KnowledgeBit(
            node_id=node.id,
            kind="learn",
            pack_index=pack_index,
            band="default",
            recipe_version=1,
            position=0,
            body={"title": "t", "markdown": "m"},
        )
    )
    for i, kind in enumerate(checks, start=1):
        session.add(
            KnowledgeBit(
                node_id=node.id,
                kind=kind,
                pack_index=pack_index,
                band="default",
                recipe_version=1,
                position=i,
                body={"type": "true_false", "prompt": "p?", "answer": True},
            )
        )
    session.flush()


def test_admin_delete_requires_admin(client, auth, session, user):
    node = KnowledgeNode(name="X", name_key="x", description="x")
    session.add(node)
    session.flush()
    _seed_pack(session, node)
    session.commit()

    denied = client.delete(
        f"/api/v1/admin/knowledge/nodes/{node.id}/packs/1",
        headers=auth,
    )
    assert denied.status_code == 403


def test_admin_delete_quiz_and_pack(client, auth, session, user):
    user.is_admin = True
    session.add(user)
    node = KnowledgeNode(name="Birds", name_key="birds", description="x")
    session.add(node)
    session.flush()
    _seed_pack(session, node)
    # learn + one check enrolls Leitner; keep a second check event for cleanup asserts.
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
                "payload": {"pack_index": 1, "correct": False, "choice_index": 1},
            },
        ],
    )
    session.commit()

    quiz = client.delete(
        f"/api/v1/admin/knowledge/nodes/{node.id}/packs/1/bits/check1",
        headers=auth,
    )
    assert quiz.status_code == 200
    body = quiz.json()
    assert body["deleted"] == "quiz"
    assert body["kind"] == "check1"
    assert set(body["remaining_checks"]) == {"check2", "check3"}

    bits = list(
        session.exec(
            select(KnowledgeBit).where(
                KnowledgeBit.node_id == node.id, KnowledgeBit.pack_index == 1
            )
        ).all()
    )
    assert {b.kind for b in bits} == {"learn", "check2", "check3"}
    assert (
        list(
            session.exec(
                select(UserTopicEvent).where(
                    UserTopicEvent.node_id == node.id, UserTopicEvent.kind == "check1"
                )
            ).all()
        )
        == []
    )
    assert (
        session.exec(
            select(UserPackReview).where(
                UserPackReview.node_id == node.id, UserPackReview.pack_index == 1
            )
        ).first()
        is not None
    )

    pack = client.delete(
        f"/api/v1/admin/knowledge/nodes/{node.id}/packs/1",
        headers=auth,
    )
    assert pack.status_code == 200
    assert pack.json()["deleted"] == "pack"
    assert list(session.exec(select(KnowledgeBit).where(KnowledgeBit.node_id == node.id)).all()) == []
    assert (
        list(
            session.exec(
                select(UserTopicEvent).where(
                    UserTopicEvent.node_id == node.id,
                    col(UserTopicEvent.kind).in_(["learn", "check2"]),
                )
            ).all()
        )
        == []
    )
    assert (
        session.exec(
            select(UserPackReview).where(
                UserPackReview.node_id == node.id, UserPackReview.pack_index == 1
            )
        ).first()
        is None
    )


def test_admin_delete_last_quiz_requires_confirm(client, auth, session, user):
    user.is_admin = True
    session.add(user)
    node = KnowledgeNode(name="Solo", name_key="solo", description="x")
    session.add(node)
    session.flush()
    _seed_pack(session, node, checks=("check1",))
    session.commit()

    blocked = client.delete(
        f"/api/v1/admin/knowledge/nodes/{node.id}/packs/1/bits/check1",
        headers=auth,
    )
    assert blocked.status_code == 409
    assert blocked.json()["code"] == "CONFIRM_PACK_DELETE"
    assert blocked.json()["details"]["would_delete_pack"] is True
    assert list(session.exec(select(KnowledgeBit).where(KnowledgeBit.node_id == node.id)).all())

    done = client.delete(
        f"/api/v1/admin/knowledge/nodes/{node.id}/packs/1/bits/check1?confirm_last_pack=true",
        headers=auth,
    )
    assert done.status_code == 200
    assert done.json()["deleted"] == "pack"
    assert list(session.exec(select(KnowledgeBit).where(KnowledgeBit.node_id == node.id)).all()) == []
