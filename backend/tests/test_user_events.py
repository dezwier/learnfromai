"""User–topic interaction event store."""

from sqlmodel import select

from app.features.knowledge_graph.node_models import KnowledgeNode
from app.features.user_events.models import UserTopicEvent


def test_focus_writes_focus_event(client, auth, session):
    opened = client.post("/api/v1/knowledge/focus", headers=auth, json={"topic": "Attention"})
    assert opened.status_code == 200
    focus_id = opened.json()["focus_node_id"]

    session.expire_all()
    rows = session.exec(select(UserTopicEvent)).all()
    assert len(rows) == 1
    assert rows[0].kind == "focus"
    assert str(rows[0].node_id) == focus_id
    assert rows[0].payload == {}


def test_post_me_events_records_learn_and_check(client, auth, session, user):
    node = KnowledgeNode(name="Softmax", name_key="softmax", description="Normalize scores.")
    session.add(node)
    session.commit()

    response = client.post(
        "/api/v1/me/events",
        headers=auth,
        json={
            "events": [
                {"node_id": str(node.id), "kind": "learn"},
                {"node_id": str(node.id), "kind": "example"},
                {
                    "node_id": str(node.id),
                    "kind": "check1",
                    "payload": {"correct": True, "choice_index": 2},
                },
                {
                    "node_id": str(node.id),
                    "kind": "check2",
                    "payload": {"correct": False, "choice_index": 0},
                },
            ]
        },
    )
    assert response.status_code == 200
    body = response.json()
    assert body["recorded"] == 4
    assert len(body["ids"]) == 4

    session.expire_all()
    rows = session.exec(
        select(UserTopicEvent)
        .where(UserTopicEvent.user_id == user.id)
        .order_by(UserTopicEvent.kind)
    ).all()
    kinds = [row.kind for row in rows]
    assert kinds == ["check1", "check2", "example", "learn"]
    check1 = next(row for row in rows if row.kind == "check1")
    assert check1.payload == {"correct": True, "choice_index": 2}
    check2 = next(row for row in rows if row.kind == "check2")
    assert check2.payload == {"correct": False, "choice_index": 0}


def test_post_me_events_rejects_focus_kind(client, auth, session):
    node = KnowledgeNode(name="QKV", name_key="qkv", description="Query key value.")
    session.add(node)
    session.commit()

    response = client.post(
        "/api/v1/me/events",
        headers=auth,
        json={"events": [{"node_id": str(node.id), "kind": "focus"}]},
    )
    assert response.status_code == 400
    assert response.json()["code"] == "INVALID_EVENTS"


def test_post_me_events_requires_check_payload(client, auth, session):
    node = KnowledgeNode(name="Embedding", name_key="embedding", description="Vector.")
    session.add(node)
    session.commit()

    response = client.post(
        "/api/v1/me/events",
        headers=auth,
        json={"events": [{"node_id": str(node.id), "kind": "check1", "payload": {}}]},
    )
    assert response.status_code == 400
    assert response.json()["code"] == "INVALID_EVENTS"


def test_post_me_events_rejects_unknown_node(client, auth):
    response = client.post(
        "/api/v1/me/events",
        headers=auth,
        json={
            "events": [
                {
                    "node_id": "00000000-0000-0000-0000-000000000001",
                    "kind": "learn",
                }
            ]
        },
    )
    assert response.status_code == 400
    assert response.json()["code"] == "INVALID_EVENTS"
