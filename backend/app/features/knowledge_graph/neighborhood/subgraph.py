"""Build API neighborhood payloads from stored edges."""

from __future__ import annotations

from collections import defaultdict, deque
from uuid import UUID

from sqlalchemy.orm import load_only
from sqlmodel import Session, col, select

from app.features.knowledge_graph.identity import same_topic
from app.features.knowledge_graph.neighborhood.constants import (
    BUCKET_RELATION,
    KIND_FOR_RELATION,
    RELATION_CHILD,
    RELATION_PARENT,
)
from app.features.knowledge_graph.node_models import KnowledgeEdge, KnowledgeNode

# Canvas paint needs titles + focus description/image path — never image BLOBs.
_NODE_CANVAS_COLS = (
    KnowledgeNode.id,
    KnowledgeNode.name,
    KnowledgeNode.description,
    KnowledgeNode.image_url,
)
_BUCKET_RELS = frozenset(BUCKET_RELATION.values())


def build_subgraph(
    session: Session,
    focus: KnowledgeNode,
    *,
    max_extended: int = 14,
    counts: dict[str, int] | None = None,
) -> dict:
    """Direct neighborhood first, then unique neighbors-of-neighbors as `extended`.

    Always show every direct neighbor. Extended tops up toward `canvas_max`
    (including focus), capped by `max_extended`. If directs alone exceed
    `canvas_max`, the canvas grows — directs are never dropped.
    """
    kinds: dict[UUID, str] = {focus.id: "focus"}
    depths: dict[UUID, int] = {focus.id: 0}
    nodes: dict[UUID, KnowledgeNode] = {focus.id: focus}
    canvas_max = int((counts or {}).get("canvas_max") or 30)
    if canvas_max < 1:
        canvas_max = 30

    focus_edges = list(
        session.exec(select(KnowledgeEdge).where(KnowledgeEdge.from_id == focus.id)).all()
    )
    direct_candidates = _nodes_by_ids(session, {edge.to_id for edge in focus_edges})

    for edge in focus_edges:
        other = direct_candidates.get(edge.to_id)
        if other is None:
            continue
        # Hide near-duplicates of the focus (Dinosaur beside Dinosaurs, etc.).
        if same_topic(other.name, focus.name):
            continue
        # Keep one title per near-duplicate cluster among directs.
        if any(same_topic(other.name, prior.name) for prior in nodes.values() if prior.id != focus.id):
            continue
        nodes[other.id] = other
        kind = KIND_FOR_RELATION.get(edge.relation, "related")
        kinds.setdefault(other.id, kind)
        if edge.relation == RELATION_PARENT:
            depths[other.id] = -1
        elif edge.relation == RELATION_CHILD:
            depths[other.id] = 1
        else:
            depths.setdefault(other.id, 0)

    via_order = ("parent", "sibling", "child", "related")
    direct_ids = [node_id for node_id in nodes if node_id != focus.id]
    directs_sorted = sorted(
        direct_ids,
        key=lambda node_id: (
            via_order.index(kinds.get(node_id, "related"))
            if kinds.get(node_id, "related") in via_order
            else 9,
            nodes[node_id].name.lower(),
            str(node_id),
        ),
    )
    direct_ids = list(directs_sorted)

    # Collect extended candidates per via-kind, then round-robin so parents/siblings
    # are not starved by child/acquaintance fan-out.
    pools: dict[str, list[KnowledgeNode]] = {kind: [] for kind in via_order}
    seen_extended: set[UUID] = set()
    seen_extended_nodes: list[KnowledgeNode] = []
    hop_by_from: dict[UUID, list[KnowledgeEdge]] = defaultdict(list)
    hop_to_ids: set[UUID] = set()
    if directs_sorted:
        for edge in session.exec(
            select(KnowledgeEdge).where(col(KnowledgeEdge.from_id).in_(directs_sorted))
        ).all():
            hop_by_from[edge.from_id].append(edge)
            if edge.to_id not in nodes:
                hop_to_ids.add(edge.to_id)
    hop_nodes = _nodes_by_ids(session, hop_to_ids)

    for direct_id in directs_sorted:
        via_kind = kinds.get(direct_id, "related")
        if via_kind not in pools:
            via_kind = "related"
        for edge in hop_by_from.get(direct_id, ()):
            if edge.to_id in nodes or edge.to_id in seen_extended:
                continue
            other = hop_nodes.get(edge.to_id)
            if other is None:
                continue
            if same_topic(other.name, focus.name):
                continue
            if any(same_topic(other.name, prior.name) for prior in nodes.values()):
                continue
            if any(same_topic(other.name, prior.name) for prior in seen_extended_nodes):
                continue
            seen_extended.add(other.id)
            seen_extended_nodes.append(other)
            pools[via_kind].append(other)

    # Top up toward canvas_max after directs; zero extended if directs already fill it.
    surrounding_slots = max(0, canvas_max - 1)
    extended_budget = min(
        max(0, int(max_extended)),
        max(0, surrounding_slots - len(direct_ids)),
    )
    extended: list[KnowledgeNode] = []
    while len(extended) < extended_budget and any(pools.values()):
        for via_kind in via_order:
            bucket = pools[via_kind]
            if not bucket:
                continue
            extended.append(bucket.pop(0))
            if len(extended) >= extended_budget:
                break

    for other in extended:
        nodes[other.id] = other
        kinds[other.id] = "extended"
        depths.setdefault(other.id, 0)

    ids = list(nodes.keys())
    edges = list(
        session.exec(
            select(KnowledgeEdge).where(
                col(KnowledgeEdge.from_id).in_(ids), col(KnowledgeEdge.to_id).in_(ids)
            )
        ).all()
    ) if ids else []
    distances = _distances(focus.id, edges)
    # Direct first, then extended; stable within each band.
    kind_rank = {"focus": 0, "parent": 1, "sibling": 2, "child": 3, "related": 4, "extended": 5}

    def sort_key(node_id: UUID) -> tuple:
        return (
            kind_rank.get(kinds.get(node_id, "related"), 9),
            depths.get(node_id, 0),
            nodes[node_id].name.lower(),
            str(node_id),
        )

    # Canvas: focus description + thumb paths for post-morph fade-in. Neighbor
    # descriptions and full image URLs stay off the wire until that node is focus.
    node_payload = []
    for node_id in sorted(ids, key=sort_key):
        node = nodes[node_id]
        is_focus = node_id == focus.id
        thumb = (
            f"/knowledge/nodes/{node.id}/image/file?variant=thumb" if node.image_url else None
        )
        node_payload.append(
            {
                "id": str(node.id),
                "title": node.name,
                "description": node.description if is_focus else None,
                "image_url": node.image_url if is_focus else None,
                "image_thumb_url": thumb,
                "depth": depths.get(node_id, 0),
                "distance": distances.get(
                    node_id, 0 if is_focus else 2 if kinds.get(node_id) == "extended" else 1
                ),
                "kind": kinds.get(node_id, "related"),
            }
        )
    # Outbound from focus + links from directs into extended (for client context).
    edge_payload = [
        {"source": str(edge.from_id), "target": str(edge.to_id), "type": edge.relation}
        for edge in sorted(edges, key=lambda row: (str(row.from_id), row.relation, str(row.to_id)))
        if edge.from_id == focus.id
        or (edge.from_id in set(direct_ids) and kinds.get(edge.to_id) == "extended")
    ]
    incomplete = False
    if counts is not None:
        total = int(counts.get("total") or sum(int(counts.get(b, 0)) for b in BUCKET_RELATION))
        have = sum(1 for edge in focus_edges if edge.relation in _BUCKET_RELS)
        incomplete = have < total
    return {
        "focus_node_id": str(focus.id),
        "incomplete": incomplete,
        "nodes": node_payload,
        "edges": edge_payload,
    }


def _nodes_by_ids(session: Session, ids: set[UUID]) -> dict[UUID, KnowledgeNode]:
    if not ids:
        return {}
    rows = session.exec(
        select(KnowledgeNode)
        .where(col(KnowledgeNode.id).in_(list(ids)))
        .options(load_only(*_NODE_CANVAS_COLS))
    ).all()
    return {row.id: row for row in rows}


def _distances(focus_id: UUID, edges: list[KnowledgeEdge]) -> dict[UUID, int]:
    adjacency: dict[UUID, set[UUID]] = {}
    for edge in edges:
        adjacency.setdefault(edge.from_id, set()).add(edge.to_id)
        adjacency.setdefault(edge.to_id, set()).add(edge.from_id)
    distances = {focus_id: 0}
    queue: deque[UUID] = deque([focus_id])
    while queue:
        current = queue.popleft()
        for neighbor in adjacency.get(current, ()):
            if neighbor in distances:
                continue
            distances[neighbor] = distances[current] + 1
            queue.append(neighbor)
    return distances
