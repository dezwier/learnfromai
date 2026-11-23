"""Thumbs up/down feedback on quiz bits."""

from app.features.content.models import KnowledgeBit, QuizBitFeedback
from app.features.knowledge_graph.node_models import KnowledgeNode
from sqlmodel import select


def test_quiz_feedback_upsert(client, auth, session, user):
    node = KnowledgeNode(name="Feedback", name_key="feedback", description="x")
    session.add(node)
    session.flush()
    bit = KnowledgeBit(
        node_id=node.id,
        kind="check1",
        pack_index=1,
        band="default",
        recipe_version=1,
        position=1,
        body={"type": "mc", "prompt": "Q?", "choices": ["a", "b", "c", "d"], "answer_index": 0},
    )
    learn = KnowledgeBit(
        node_id=node.id,
        kind="learn",
        pack_index=1,
        band="default",
        recipe_version=1,
        position=0,
        body={"title": "t", "markdown": "m"},
    )
    session.add(learn)
    session.add(bit)
    session.commit()

    up = client.post(
        f"/api/v1/knowledge/bits/{bit.id}/feedback",
        headers=auth,
        json={"rating": 1},
    )
    assert up.status_code == 200
    assert up.json()["rating"] == 1
    assert up.json()["bit_id"] == str(bit.id)

    down = client.post(
        f"/api/v1/knowledge/bits/{bit.id}/feedback",
        headers=auth,
        json={"rating": -1},
    )
    assert down.status_code == 200
    assert down.json()["rating"] == -1

    rows = session.exec(select(QuizBitFeedback).where(QuizBitFeedback.bit_id == bit.id)).all()
    assert len(rows) == 1
    assert rows[0].user_id == user.id
    assert rows[0].rating == -1

    clear = client.post(
        f"/api/v1/knowledge/bits/{bit.id}/feedback",
        headers=auth,
        json={"rating": None},
    )
    assert clear.status_code == 200
    assert clear.json()["rating"] is None
    assert session.exec(select(QuizBitFeedback).where(QuizBitFeedback.bit_id == bit.id)).all() == []

    bad = client.post(
        f"/api/v1/knowledge/bits/{bit.id}/feedback",
        headers=auth,
        json={"rating": 2},
    )
    assert bad.status_code == 422

    learn_fb = client.post(
        f"/api/v1/knowledge/bits/{learn.id}/feedback",
        headers=auth,
        json={"rating": 1},
    )
    assert learn_fb.status_code == 422
