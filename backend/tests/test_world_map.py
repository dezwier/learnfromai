from uuid import uuid4

from app.features.knowledge_graph.node_models import KnowledgeEdge, KnowledgeNode
from app.features.knowledge_graph.world_map import (
    cube_distance,
    ensure_world_placed,
    map_window,
    spiral_cells,
)


def test_spiral_starts_at_origin_and_grows():
    cells = list(spiral_cells(7))
    assert cells[0] == (0, 0)
    assert len(cells) == 7
    assert len(set(cells)) == 7
    assert max(cube_distance(q, r) for q, r in cells) == 1


def test_roots_center_children_outward(session):
    root = KnowledgeNode(id=uuid4(), name="Science", name_key="science")
    child = KnowledgeNode(id=uuid4(), name="Biology", name_key="biology")
    grand = KnowledgeNode(id=uuid4(), name="Zoology", name_key="zoology")
    session.add_all([root, child, grand])
    session.flush()
    session.add_all(
        [
            KnowledgeEdge(from_id=child.id, relation="parent", to_id=root.id),
            KnowledgeEdge(from_id=root.id, relation="child", to_id=child.id),
            KnowledgeEdge(from_id=grand.id, relation="parent", to_id=child.id),
            KnowledgeEdge(from_id=child.id, relation="child", to_id=grand.id),
        ]
    )
    session.commit()

    placed = ensure_world_placed(session)
    session.commit()
    assert placed == 3

    session.refresh(root)
    session.refresh(child)
    session.refresh(grand)
    assert root.map_depth == 0
    assert child.map_depth == 1
    assert grand.map_depth == 2
    assert (root.q, root.r) == (0, 0)
    assert cube_distance(child.q, child.r) >= 1
    assert cube_distance(grand.q, grand.r) >= cube_distance(child.q, child.r)
    # Stable: second call places nothing.
    assert ensure_world_placed(session) == 0


def test_map_window_filters_and_includes_edges(client, auth, session):
    a = KnowledgeNode(id=uuid4(), name="A", name_key="a", q=0, r=0, map_depth=0)
    b = KnowledgeNode(id=uuid4(), name="B", name_key="b", q=1, r=0, map_depth=1)
    far = KnowledgeNode(id=uuid4(), name="Far", name_key="far", q=40, r=40, map_depth=2)
    session.add_all([a, b, far])
    session.flush()
    session.add(KnowledgeEdge(from_id=a.id, relation="child", to_id=b.id))
    session.commit()

    payload = map_window(session, qmin=-1, qmax=2, rmin=-1, rmax=2, margin=0)
    ids = {n["id"] for n in payload["nodes"]}
    assert str(a.id) in ids
    assert str(b.id) in ids
    assert str(far.id) not in ids
    assert any(e["source"] == str(a.id) and e["target"] == str(b.id) for e in payload["edges"])

    http = client.get(
        "/api/v1/knowledge/map",
        headers=auth,
        params={"qmin": -1, "qmax": 2, "rmin": -1, "rmax": 2, "margin": 0},
    )
    assert http.status_code == 200
    assert {n["id"] for n in http.json()["nodes"]} == ids
