"""Per-user topic affinity scores and edge-based clusters."""

from __future__ import annotations

from collections import defaultdict
from uuid import UUID

from sqlmodel import Session, col, select

from app.features.accounts.models import User
from app.features.knowledge_graph.node_models import KnowledgeEdge, KnowledgeNode
from app.features.user_events.models import UserTopicEvent

DEFAULT_LIMIT = 24
MAX_LIMIT = 48
FOCUS_POINTS = 1
OPEN_POINTS = 2
LEARNED_POINTS = 3
LEARNED_KINDS = frozenset({"learn", "example", "check1", "check2", "check3"})


def topic_affinity(
    session: Session,
    *,
    user: User,
    limit: int = DEFAULT_LIMIT,
) -> dict:
    """Score topics from events, keep top-N, cluster by induced knowledge edges."""
    capped = max(1, min(int(limit or DEFAULT_LIMIT), MAX_LIMIT))
    scored = _score_nodes(session, user_id=user.id)
    if not scored:
        return {"nodes": [], "clusters": [], "edges": []}

    ranked = sorted(scored.values(), key=lambda row: (-row["affinity"], row["name"].lower()))
    top = ranked[:capped]
    ids = [row["id"] for row in top]
    id_set = set(ids)

    edge_rows = session.exec(
        select(KnowledgeEdge).where(
            col(KnowledgeEdge.from_id).in_(ids),
            col(KnowledgeEdge.to_id).in_(ids),
        )
    ).all()

    # Undirected unique links for clustering (prefer one direction of each pair).
    undirected: list[tuple[UUID, UUID, str]] = []
    seen_pairs: set[tuple[UUID, UUID]] = set()
    for edge in edge_rows:
        a, b = edge.from_id, edge.to_id
        if a not in id_set or b not in id_set or a == b:
            continue
        key = (a, b) if a.hex < b.hex else (b, a)
        if key in seen_pairs:
            continue
        seen_pairs.add(key)
        undirected.append((key[0], key[1], edge.relation))

    parent = {nid: nid for nid in ids}

    def find(nid: UUID) -> UUID:
        while parent[nid] != nid:
            parent[nid] = parent[parent[nid]]
            nid = parent[nid]
        return nid

    def union(a: UUID, b: UUID) -> None:
        ra, rb = find(a), find(b)
        if ra != rb:
            parent[rb] = ra

    for a, b, _ in undirected:
        union(a, b)

    components: dict[UUID, list[UUID]] = defaultdict(list)
    for nid in ids:
        components[find(nid)].append(nid)

    affinity_by_id = {row["id"]: row["affinity"] for row in top}
    cluster_specs: list[dict] = []
    for members in components.values():
        seed = max(members, key=lambda nid: (affinity_by_id[nid], -ids.index(nid)))
        total = sum(affinity_by_id[nid] for nid in members)
        cluster_specs.append(
            {
                "seed_node_id": seed,
                "total_affinity": total,
                "node_ids": sorted(members, key=lambda nid: (-affinity_by_id[nid], ids.index(nid))),
            }
        )
    cluster_specs.sort(
        key=lambda spec: (-spec["total_affinity"], -affinity_by_id[spec["seed_node_id"]])
    )

    cluster_id_by_node: dict[UUID, int] = {}
    clusters_out: list[dict] = []
    for index, spec in enumerate(cluster_specs):
        clusters_out.append(
            {
                "id": index,
                "seed_node_id": str(spec["seed_node_id"]),
                "total_affinity": spec["total_affinity"],
                "node_ids": [str(nid) for nid in spec["node_ids"]],
            }
        )
        for nid in spec["node_ids"]:
            cluster_id_by_node[nid] = index

    nodes_out = []
    for row in top:
        nid = row["id"]
        nodes_out.append(
            {
                "id": str(nid),
                "name": row["name"],
                "affinity": row["affinity"],
                "focus_count": row["focus_count"],
                "open_count": row["open_count"],
                "learned": row["learned"],
                "image_thumb_url": (
                    f"/knowledge/nodes/{nid}/image/file?variant=thumb" if row["has_image"] else None
                ),
                "cluster_id": cluster_id_by_node[nid],
            }
        )

    edges_out = [
        {"source": str(a), "target": str(b), "type": relation} for a, b, relation in undirected
    ]
    return {"nodes": nodes_out, "clusters": clusters_out, "edges": edges_out}


def _score_nodes(session: Session, *, user_id: UUID) -> dict[UUID, dict]:
    events = session.exec(
        select(UserTopicEvent).where(UserTopicEvent.user_id == user_id)
    ).all()
    if not events:
        return {}

    focus_counts: dict[UUID, int] = defaultdict(int)
    open_counts: dict[UUID, int] = defaultdict(int)
    learned_nodes: set[UUID] = set()
    node_ids: set[UUID] = set()

    for event in events:
        node_ids.add(event.node_id)
        if event.kind == "focus":
            focus_counts[event.node_id] += 1
        elif event.kind == "open":
            open_counts[event.node_id] += 1
        elif event.kind in LEARNED_KINDS:
            learned_nodes.add(event.node_id)

    if not node_ids:
        return {}

    nodes = session.exec(select(KnowledgeNode).where(col(KnowledgeNode.id).in_(node_ids))).all()
    by_id = {node.id: node for node in nodes}

    scored: dict[UUID, dict] = {}
    for nid in node_ids:
        node = by_id.get(nid)
        if node is None:
            continue
        focus_n = focus_counts.get(nid, 0)
        open_n = open_counts.get(nid, 0)
        learned = nid in learned_nodes
        affinity = focus_n * FOCUS_POINTS + open_n * OPEN_POINTS + (LEARNED_POINTS if learned else 0)
        if affinity <= 0:
            continue
        scored[nid] = {
            "id": nid,
            "name": node.name,
            "affinity": affinity,
            "focus_count": focus_n,
            "open_count": open_n,
            "learned": learned,
            "has_image": bool(node.image_url),
        }
    return scored
