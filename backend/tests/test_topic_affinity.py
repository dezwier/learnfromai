"""Topic affinity scoring and clustering for the profile map."""

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

    record_focus(session, user=user, node_id=attention.id)
    record_focus(session, user=user, node_id=attention.id)
    record_focus(session, user=user, node_id=softmax.id)
    record_focus(session, user=user, node_id=embedding.id)
    record_events(
        session,
        user=user,
        items=[
            {"node_id": str(attention.id), "kind": "open", "payload": {"source": "graph"}},
            {"node_id": str(attention.id), "kind": "open", "payload": {"source": "search"}},
            {"node_id": str(attention.id), "kind": "learn"},
            {"node_id": str(softmax.id), "kind": "open", "payload": {"source": "list"}},
            {"node_id": str(softmax.id), "kind": "example"},
            {"node_id": str(softmax.id), "kind": "check1", "payload": {"correct": True, "choice_index": 1}},
        ],
    )
    session.commit()

    response = client.get("/api/v1/me/topic-affinity", headers=auth)
    assert response.status_code == 200
    body = response.json()
    by_name = {row["name"]: row for row in body["nodes"]}

    # Attention: 2 focus (+2) + 2 open (+4) + learned (+3) = 9
    assert by_name["Attention"]["affinity"] == 9
    assert by_name["Attention"]["focus_count"] == 2
    assert by_name["Attention"]["open_count"] == 2
    assert by_name["Attention"]["learned"] is True

    # Softmax: 1 focus (+1) + 1 open (+2) + learned once (+3) = 6
    assert by_name["Softmax"]["affinity"] == 6
    assert by_name["Softmax"]["learned"] is True

    # Embedding: 1 focus only = 1
    assert by_name["Embedding"]["affinity"] == 1
    assert by_name["Embedding"]["learned"] is False

    assert body["nodes"][0]["name"] == "Attention"
    assert len(body["clusters"]) == 2
    linked = next(c for c in body["clusters"] if set(c["node_ids"]) == {str(attention.id), str(softmax.id)})
    alone = next(c for c in body["clusters"] if c["node_ids"] == [str(embedding.id)])
    assert linked["total_affinity"] == 15
    assert alone["total_affinity"] == 1
    assert by_name["Attention"]["cluster_id"] == linked["id"]
    assert by_name["Softmax"]["cluster_id"] == linked["id"]
    assert by_name["Embedding"]["cluster_id"] == alone["id"]
    assert any(
        {edge["source"], edge["target"]} == {str(attention.id), str(softmax.id)}
        for edge in body["edges"]
    )


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
    for node in nodes:
        session.add(UserTopicEvent(user_id=user.id, node_id=node.id, kind="focus", payload={}))
    session.commit()

    response = client.get("/api/v1/me/topic-affinity?limit=2", headers=auth)
    assert response.status_code == 200
    assert len(response.json()["nodes"]) == 2
