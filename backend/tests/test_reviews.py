"""Leitner testing track: enroll, due queue, submit moves."""

from datetime import timedelta
from uuid import uuid4

from sqlmodel import select

from app.core.time import utcnow
from app.features.content.models import KnowledgeBit
from app.features.knowledge_graph.node_models import KnowledgeNode
from app.features.reviews.models import UserPackReview
from app.features.reviews.srs import apply_review_result, enroll_first_learn, interval_hours_for_bin


def _seed_pack(session, *, name: str = "Attention") -> KnowledgeNode:
    node = KnowledgeNode(name=name, name_key=name.lower(), description=f"{name} topic.")
    session.add(node)
    session.flush()
    session.add(
        KnowledgeBit(
            node_id=node.id,
            pack_index=1,
            kind="learn",
            position=0,
            body={"title": name, "markdown": f"Learn {name}."},
        )
    )
    for i, kind in enumerate(("check1", "check2", "check3"), start=1):
        session.add(
            KnowledgeBit(
                node_id=node.id,
                pack_index=1,
                kind=kind,
                position=i,
                body={
                    "type": "mc",
                    "question": f"Q{i}?",
                    "choices": ["a", "b", "c", "d"],
                    "answer_index": 0,
                    "explanation": "Because.",
                },
            )
        )
    session.commit()
    return node


def _complete_pack(client, auth, node_id, *, pack_index: int = 1):
    response = client.post(
        "/api/v1/me/events",
        headers=auth,
        json={
            "events": [
                {
                    "node_id": str(node_id),
                    "kind": "learn",
                    "payload": {"pack_index": pack_index},
                },
                {
                    "node_id": str(node_id),
                    "kind": "check1",
                    "payload": {
                        "pack_index": pack_index,
                        "correct": True,
                        "choice_index": 0,
                    },
                },
            ]
        },
    )
    assert response.status_code == 200


def test_interval_hours_for_bin():
    assert interval_hours_for_bin(1) == 24
    assert interval_hours_for_bin(2) == 48
    assert interval_hours_for_bin(3) == 96
    assert interval_hours_for_bin(4) == 168
    assert interval_hours_for_bin(5) == 336
    assert interval_hours_for_bin(6) == 504
    assert interval_hours_for_bin(7) == 672
    assert interval_hours_for_bin(8) == 1008
    assert interval_hours_for_bin(9) == 1344
    assert interval_hours_for_bin(10) == 1680


def test_apply_review_result_moves():
    now = utcnow()
    row = UserPackReview(user_id=uuid4(), node_id=uuid4(), pack_index=1)
    enroll_first_learn(row, at=now)
    assert row.leitner_bin == 1

    # Not due yet → no move.
    assert apply_review_result(row, correct=True, at=now + timedelta(hours=1)) is False
    assert row.leitner_bin == 1

    due_at = row.next_review_at
    assert due_at is not None
    assert apply_review_result(row, correct=True, at=due_at) is True
    assert row.leitner_bin == 2

    due_at = row.next_review_at
    assert apply_review_result(row, correct=False, at=due_at) is True
    assert row.leitner_bin == 1


def test_apply_review_result_graduates_at_7():
    now = utcnow()
    row = UserPackReview(
        user_id=uuid4(),
        node_id=uuid4(),
        pack_index=1,
        leitner_bin=6,
        next_review_at=now,
    )
    assert apply_review_result(row, correct=True, at=now) is True
    assert row.leitner_bin == 7
    assert row.graduated_at is not None

    due_at = row.next_review_at
    assert apply_review_result(row, correct=True, at=due_at) is True
    assert row.leitner_bin == 8
    assert row.graduated_at is not None


def test_complete_pack_enrolls_bin_1(client, auth, session):
    node = _seed_pack(session)
    _complete_pack(client, auth, node.id)

    session.expire_all()
    row = session.exec(select(UserPackReview)).one()
    assert row.leitner_bin == 1
    assert row.next_review_at is not None
    assert row.node_id == node.id
    assert row.pack_index == 1


def test_distribution_and_due_after_making_due(client, auth, session):
    node = _seed_pack(session, name="Transformer")
    _complete_pack(client, auth, node.id)

    dist = client.get("/api/v1/me/reviews/distribution", headers=auth)
    assert dist.status_code == 200
    body = dist.json()
    assert body["graduation_bin"] == 7
    assert body["due_count"] == 0
    assert body["distribution"][0]["bin"] == 1
    assert body["distribution"][0]["count"] == 1
    assert body["distribution"][0]["count_not_due"] == 1

    due = client.get("/api/v1/me/reviews/due", headers=auth)
    assert due.status_code == 200
    assert due.json()["items"] == []
    assert due.json()["due_count"] == 0

    session.expire_all()
    row = session.exec(select(UserPackReview)).one()
    row.next_review_at = utcnow() - timedelta(minutes=1)
    session.add(row)
    session.commit()

    due2 = client.get("/api/v1/me/reviews/due", headers=auth)
    assert due2.status_code == 200
    payload = due2.json()
    assert payload["due_count"] == 1
    assert len(payload["items"]) == 1
    item = payload["items"][0]
    assert item["node_id"] == str(node.id)
    assert item["pack_index"] == 1
    assert item["leitner_bin"] == 1
    assert len(item["pack"]["bits"]) >= 2

    dist2 = client.get("/api/v1/me/reviews/distribution", headers=auth).json()
    assert dist2["due_count"] == 1
    assert dist2["distribution"][0]["count_due"] == 1


def test_submit_correct_moves_up_incorrect_moves_down(client, auth, session):
    node = _seed_pack(session, name="Softmax")
    _complete_pack(client, auth, node.id)

    session.expire_all()
    row = session.exec(select(UserPackReview)).one()
    row.next_review_at = utcnow() - timedelta(seconds=1)
    session.add(row)
    session.commit()

    up = client.post(
        "/api/v1/me/reviews/submit",
        headers=auth,
        json={
            "node_id": str(node.id),
            "pack_index": 1,
            "correct": True,
            "check_kind": "check2",
            "choice_index": 0,
        },
    )
    assert up.status_code == 200
    assert up.json()["leitner_bin"] == 2
    assert up.json()["updated"] is True

    session.expire_all()
    row = session.exec(select(UserPackReview)).one()
    assert row.leitner_bin == 2
    row.next_review_at = utcnow() - timedelta(seconds=1)
    session.add(row)
    session.commit()

    down = client.post(
        "/api/v1/me/reviews/submit",
        headers=auth,
        json={
            "node_id": str(node.id),
            "pack_index": 1,
            "correct": False,
            "check_kind": "check3",
            "choice_index": 1,
        },
    )
    assert down.status_code == 200
    assert down.json()["leitner_bin"] == 1


def test_submit_not_due_is_noop(client, auth, session):
    node = _seed_pack(session, name="LayerNorm")
    _complete_pack(client, auth, node.id)

    response = client.post(
        "/api/v1/me/reviews/submit",
        headers=auth,
        json={
            "node_id": str(node.id),
            "pack_index": 1,
            "correct": True,
            "check_kind": "check1",
            "choice_index": 0,
        },
    )
    assert response.status_code == 200
    assert response.json()["updated"] is False
    assert response.json()["leitner_bin"] == 1
