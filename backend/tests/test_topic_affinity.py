"""Topic affinity scoring and clustering for the profile map."""

import pytest

from app.features.knowledge_graph.node_models import KnowledgeEdge, KnowledgeNode
from app.features.user_events.models import UserTopicEvent
from app.features.user_events.service import record_events, record_focus


def test_topic_affinity_scores_and_clusters(client, auth, session, user):
    attention = KnowledgeNode(name="Attention", name_key="attention", description="Weighting.")
    softmax = KnowledgeNode(name="Softmax", name_key="softmax", description="Normalize.")
    embedding = KnowledgeNode(name="Embedding", name_key="embedding", description="Vector.")
    session.add(attention)
    session.add(softmax)
    session.add(embedding)
    session.flush()
    session.add(KnowledgeEdge(from_id=attention.id, relation="child", to_id=softmax.id))
    session.add(KnowledgeEdge(from_id=softmax.id, relation="parent", to_id=attention.id))
    session.commit()

    # Cold-start style focus must not affect interest.
    record_focus(session, user=user, node_id=attention.id)
    record_focus(session, user=user, node_id=attention.id)
    record_events(
        session,
        user=user,
        items=[
            {"node_id": str(attention.id), "kind": "open", "payload": {"source": "graph"}},
            {"node_id": str(attention.id), "kind": "open", "payload": {"source": "search"}},
            {"node_id": str(attention.id), "kind": "learn"},
            {"node_id": str(softmax.id), "kind": "open", "payload": {"source": "list"}},
            {"node_id": str(softmax.id), "kind": "example"},
            {
                "node_id": str(softmax.id),
                "kind": "check1",
                "payload": {"correct": True, "choice_index": 1},
            },
            {"node_id": str(embedding.id), "kind": "open", "payload": {"source": "settings"}},
        ],
    )
    session.commit()

    response = client.get("/api/v1/me/topic-affinity", headers=auth)
    assert response.status_code == 200
    body = response.json()
    by_name = {row["name"]: row for row in body["nodes"]}

    # Opens only: Attention=2, Softmax=1, Embedding=1 → total=4.
    # Attention: 2/4 + Softmax-neighbor 1/4 + recency 1 = 1.75
    assert by_name["Attention"]["affinity"] == pytest.approx(2 / 4 + 1 / 4 + 1, abs=0.05)
    assert by_name["Attention"]["focus_count"] == 2  # recorded but not in interest
    assert by_name["Attention"]["open_count"] == 2
    assert by_name["Attention"]["learned"] is True
    assert by_name["Attention"]["breakdown"]["interest"] == pytest.approx(2 / 4, abs=1e-4)
    assert by_name["Attention"]["breakdown"]["neighbor"] == pytest.approx(1 / 4, abs=1e-4)
    assert by_name["Attention"]["breakdown"]["recency"] == pytest.approx(1.0, abs=0.05)

    assert by_name["Softmax"]["affinity"] == pytest.approx(1 / 4 + 2 / 4 + 1, abs=0.05)
    assert by_name["Softmax"]["learned"] is True

    assert by_name["Embedding"]["affinity"] == pytest.approx(1 / 4 + 1, abs=0.05)
    assert by_name["Embedding"]["open_count"] == 1
    assert by_name["Embedding"]["learned"] is False

    assert {by_name["Attention"]["rank"], by_name["Softmax"]["rank"]} == {1, 2}
    assert by_name["Embedding"]["rank"] == 3
    assert len(body["clusters"]) == 2
    linked = next(
        c for c in body["clusters"] if set(c["node_ids"]) == {str(attention.id), str(softmax.id)}
    )
    alone = next(c for c in body["clusters"] if c["node_ids"] == [str(embedding.id)])
    assert linked["total_affinity"] == pytest.approx(
        (2 / 4 + 1 / 4 + 1) + (1 / 4 + 2 / 4 + 1), abs=0.1
    )
    assert alone["total_affinity"] == pytest.approx(1 / 4 + 1, abs=0.05)
    assert by_name["Attention"]["cluster_id"] == linked["id"]
    assert by_name["Softmax"]["cluster_id"] == linked["id"]
    assert by_name["Embedding"]["cluster_id"] == alone["id"]
    assert any(
        {edge["source"], edge["target"]} == {str(attention.id), str(softmax.id)}
        for edge in body["edges"]
    )


def test_topic_affinity_ignores_focus_only(client, auth, session, user):
    node = KnowledgeNode(name="Quiet", name_key="quiet", description="x")
    session.add(node)
    session.flush()
    record_focus(session, user=user, node_id=node.id)
    session.commit()

    response = client.get("/api/v1/me/topic-affinity", headers=auth)
    assert response.status_code == 200
    assert response.json() == {"nodes": [], "clusters": [], "edges": []}


def test_topic_affinity_empty(client, auth):
    response = client.get("/api/v1/me/topic-affinity", headers=auth)
    assert response.status_code == 200
    assert response.json() == {"nodes": [], "clusters": [], "edges": []}


def test_topic_affinity_limit(client, auth, session, user):
    nodes = []
    for i in range(5):
        node = KnowledgeNode(name=f"Topic {i}", name_key=f"topic-{i}", description="x")
        session.add(node)
        nodes.append(node)
    session.flush()
    record_events(
        session,
        user=user,
        items=[
            {"node_id": str(node.id), "kind": "open", "payload": {"source": "graph"}}
            for node in nodes
        ],
    )
    session.commit()

    response = client.get("/api/v1/me/topic-affinity?limit=2", headers=auth)
    assert response.status_code == 200
    assert len(response.json()["nodes"]) == 2
