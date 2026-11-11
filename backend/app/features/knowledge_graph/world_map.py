"""Stable radial hex world: roots near origin, children outward by depth."""

from __future__ import annotations

from collections import defaultdict, deque
from uuid import UUID

from sqlalchemy import and_
from sqlmodel import Session, col, select

from app.features.knowledge_graph.node_models import KnowledgeEdge, KnowledgeNode

RELATION_PARENT = "parent"
RELATION_CHILD = "child"

# Flat-top axial neighbor offsets (q, r).
_HEX_DIRS = ((1, 0), (1, -1), (0, -1), (-1, 0), (-1, 1), (0, 1))


def cube_distance(q: int, r: int) -> int:
    s = -q - r
    return (abs(q) + abs(r) + abs(s)) // 2


def spiral_cells(limit: int):
    """Yield axial cells in spiral order starting at (0, 0)."""
    yield (0, 0)
    ring = 1
    produced = 1
    while produced < limit:
        # Start on ring at direction index 4, then walk each edge `ring` steps.
        q = _HEX_DIRS[4][0] * ring
        r = _HEX_DIRS[4][1] * ring
        for dq, dr in _HEX_DIRS:
            for _ in range(ring):
                yield (q, r)
                produced += 1
                if produced >= limit:
                    return
                q += dq
                r += dr
        ring += 1


def ring_around(cq: int, cr: int, radius: int) -> list[tuple[int, int]]:
    if radius <= 0:
        return [(cq, cr)]
    q = cq + _HEX_DIRS[4][0] * radius
    r = cr + _HEX_DIRS[4][1] * radius
    cells: list[tuple[int, int]] = []
    for dq, dr in _HEX_DIRS:
        for _ in range(radius):
            cells.append((q, r))
            q += dq
            r += dr
    return cells


def ensure_world_placed(session: Session) -> int:
    """Assign axial coords to every unplaced node. Returns how many were placed."""
    nodes = list(session.exec(select(KnowledgeNode)).all())
    if not nodes:
        return 0
    edges = list(session.exec(select(KnowledgeEdge)).all())
    parents_of, children_of = _parent_child_maps(edges)
    depths, primary_parent = _depths_and_primary(nodes, parents_of)

    occupied: set[tuple[int, int]] = set()
    for node in nodes:
        if node.q is not None and node.r is not None:
            occupied.add((node.q, node.r))

    placed = 0
    # Roots first (depth 0), stable by id.
    roots = sorted(
        [n for n in nodes if depths.get(n.id, 0) == 0 and (n.q is None or n.r is None)],
        key=lambda n: str(n.id),
    )
    spiral = spiral_cells(max(len(roots) * 4, 64))
    for node in roots:
        for cell in spiral:
            if cell not in occupied:
                node.q, node.r = cell
                node.map_depth = 0
                occupied.add(cell)
                session.add(node)
                placed += 1
                break

    # Refresh placed roots into a lookup for children.
    by_id = {n.id: n for n in nodes}
    max_depth = max(depths.values(), default=0)
    for depth in range(1, max_depth + 1):
        layer = sorted(
            [n for n in nodes if depths.get(n.id) == depth and (n.q is None or n.r is None)],
            key=lambda n: str(n.id),
        )
        for node in layer:
            parent_id = primary_parent.get(node.id)
            parent = by_id.get(parent_id) if parent_id else None
            if parent is None or parent.q is None or parent.r is None:
                # Fallback: treat like a root near origin.
                cell = _first_free(spiral_cells(10_000), occupied)
            else:
                cell = _place_near_parent(
                    occupied,
                    parent_q=parent.q,
                    parent_r=parent.r,
                    outward=True,
                )
            if cell is None:
                continue
            node.q, node.r = cell
            node.map_depth = depth
            occupied.add(cell)
            session.add(node)
            placed += 1

    # Fill map_depth for already-placed nodes missing it.
    for node in nodes:
        if node.map_depth is None and node.id in depths:
            node.map_depth = depths[node.id]
            session.add(node)

    if placed:
        session.flush()
    return placed


def map_window(
    session: Session,
    *,
    qmin: int,
    qmax: int,
    rmin: int,
    rmax: int,
    margin: int = 2,
) -> dict:
    """Nodes whose axial coords fall in the padded window, plus edges among them."""
    ensure_world_placed(session)
    qq0, qq1 = qmin - margin, qmax + margin
    rr0, rr1 = rmin - margin, rmax + margin
    rows = list(
        session.exec(
            select(KnowledgeNode).where(
                and_(
                    col(KnowledgeNode.q).is_not(None),
                    col(KnowledgeNode.r).is_not(None),
                    col(KnowledgeNode.q) >= qq0,
                    col(KnowledgeNode.q) <= qq1,
                    col(KnowledgeNode.r) >= rr0,
                    col(KnowledgeNode.r) <= rr1,
                )
            )
        ).all()
    )
    ids = [row.id for row in rows]
    edges: list[KnowledgeEdge] = []
    if ids:
        edges = list(
            session.exec(
                select(KnowledgeEdge).where(
                    col(KnowledgeEdge.from_id).in_(ids),
                    col(KnowledgeEdge.to_id).in_(ids),
                )
            ).all()
        )
    return {
        "nodes": [_node_dict(row) for row in sorted(rows, key=lambda n: (n.map_depth or 0, n.name.lower(), str(n.id)))],
        "edges": [
            {"source": str(e.from_id), "target": str(e.to_id), "type": e.relation}
            for e in sorted(edges, key=lambda row: (str(row.from_id), row.relation, str(row.to_id)))
        ],
        "window": {"qmin": qq0, "qmax": qq1, "rmin": rr0, "rmax": rr1},
    }


def node_coords_payload(node: KnowledgeNode) -> dict:
    return {
        "q": node.q,
        "r": node.r,
        "depth": node.map_depth if node.map_depth is not None else 0,
    }


def _node_dict(node: KnowledgeNode) -> dict:
    return {
        "id": str(node.id),
        "title": node.name,
        "description": node.description,
        "q": node.q,
        "r": node.r,
        "depth": node.map_depth if node.map_depth is not None else 0,
        "kind": "topic",
        "distance": node.map_depth if node.map_depth is not None else 0,
    }


def _parent_child_maps(edges: list[KnowledgeEdge]) -> tuple[dict[UUID, list[UUID]], dict[UUID, list[UUID]]]:
    parents_of: dict[UUID, list[UUID]] = defaultdict(list)
    children_of: dict[UUID, list[UUID]] = defaultdict(list)
    for edge in edges:
        if edge.relation == RELATION_PARENT:
            parents_of[edge.from_id].append(edge.to_id)
            children_of[edge.to_id].append(edge.from_id)
        elif edge.relation == RELATION_CHILD:
            children_of[edge.from_id].append(edge.to_id)
            parents_of[edge.to_id].append(edge.from_id)
    # Deduplicate while keeping stable order.
    for mapping in (parents_of, children_of):
        for key, values in list(mapping.items()):
            mapping[key] = sorted(set(values), key=str)
    return parents_of, children_of


def _depths_and_primary(
    nodes: list[KnowledgeNode],
    parents_of: dict[UUID, list[UUID]],
) -> tuple[dict[UUID, int], dict[UUID, UUID]]:
    """Shortest parent-chain to a root; primary parent on that path (tie-break id)."""
    ids = {n.id for n in nodes}
    roots = [n.id for n in nodes if not parents_of.get(n.id)]
    depths: dict[UUID, int] = {root: 0 for root in roots}
    primary: dict[UUID, UUID] = {}
    # BFS from roots downward using inverse of parents_of (children).
    children_of: dict[UUID, list[UUID]] = defaultdict(list)
    for child, parents in parents_of.items():
        for parent in parents:
            children_of[parent].append(child)
    for parent in children_of:
        children_of[parent] = sorted(set(children_of[parent]), key=str)

    queue: deque[UUID] = deque(sorted(roots, key=str))
    while queue:
        current = queue.popleft()
        for child in children_of.get(current, []):
            if child not in ids:
                continue
            next_depth = depths[current] + 1
            if child not in depths or next_depth < depths[child]:
                depths[child] = next_depth
                primary[child] = current
                queue.append(child)
            elif next_depth == depths[child]:
                # Stable primary: lexicographically smaller parent id.
                prev = primary.get(child)
                if prev is None or str(current) < str(prev):
                    primary[child] = current

    # Orphans / cycles with no path to a declared root → treat as roots.
    for node in nodes:
        if node.id not in depths:
            depths[node.id] = 0
    return depths, primary


def _place_near_parent(
    occupied: set[tuple[int, int]],
    *,
    parent_q: int,
    parent_r: int,
    outward: bool,
) -> tuple[int, int] | None:
    parent_dist = cube_distance(parent_q, parent_r)
    for radius in range(1, 48):
        candidates = ring_around(parent_q, parent_r, radius)
        if outward:
            candidates.sort(
                key=lambda cell: (
                    -cube_distance(cell[0], cell[1]) if cube_distance(cell[0], cell[1]) > parent_dist else 1,
                    cube_distance(cell[0], cell[1]),
                    cell[0],
                    cell[1],
                )
            )
        else:
            candidates.sort(key=lambda cell: (cube_distance(cell[0], cell[1]), cell[0], cell[1]))
        for cell in candidates:
            if cell not in occupied:
                return cell
    return None


def _first_free(cells, occupied: set[tuple[int, int]]) -> tuple[int, int] | None:
    for cell in cells:
        if cell not in occupied:
            return cell
    return None
