"""Per-user topic affinity for the profile map (clusters on ranked tiles)."""

from __future__ import annotations

from collections import defaultdict
from uuid import UUID

from sqlmodel import Session, col, select

from app.features.accounts.models import User
from app.features.knowledge_graph.node_models import KnowledgeEdge
from app.features.ranking.affinity import score_user_tiles

DEFAULT_LIMIT = 24
MAX_LIMIT = 48


def topic_affinity(
    session: Session,
    *,
    user: User,
    limit: int = DEFAULT_LIMIT,
) -> dict:
    """Score topics with the shared ranking formula, keep top-N, cluster by edges."""
    capped = max(1, min(int(limit or DEFAULT_LIMIT), MAX_LIMIT))
    scored = score_user_tiles(session, user_id=user.id)
    if not scored:
        return {"nodes": [], "clusters": [], "edges": []}

    ranked = sorted(
        scored.values(),
        key=lambda row: (-float(row["affinity"]), row["name"].lower()),
    )
    top = ranked[:capped]
    ids = [row["id"] for row in top]
    id_set = set(ids)

    edge_rows = session.exec(
        select(KnowledgeEdge).where(
            col(KnowledgeEdge.from_id).in_(ids),
            col(KnowledgeEdge.to_id).in_(ids),
        )
    ).all()

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

    affinity_by_id = {row["id"]: float(row["affinity"]) for row in top}
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
                "total_affinity": round(float(spec["total_affinity"]), 4),
                "node_ids": [str(nid) for nid in spec["node_ids"]],
            }
        )
        for nid in spec["node_ids"]:
            cluster_id_by_node[nid] = index

    nodes_out = []
    for rank, row in enumerate(top, start=1):
        nid = row["id"]
        breakdown = row.get("breakdown") or {}
        nodes_out.append(
            {
                "id": str(nid),
                "name": row["name"],
                "rank": rank,
                "affinity": round(float(row["affinity"]), 4),
                "focus_count": row["focus_count"],
                "open_count": row["open_count"],
                "learned": row["learned"],
                "image_thumb_url": (
                    f"/knowledge/nodes/{nid}/image/file?variant=thumb" if row["has_image"] else None
                ),
                "cluster_id": cluster_id_by_node[nid],
                "breakdown": {
                    "interest": round(float(breakdown.get("interest") or 0), 4),
                    "neighbor": round(float(breakdown.get("neighbor") or 0), 4),
                    "recency": round(float(breakdown.get("recency") or 0), 4),
                },
            }
        )

    edges_out = [
        {"source": str(a), "target": str(b), "type": relation} for a, b, relation in undirected
    ]
    return {"nodes": nodes_out, "clusters": clusters_out, "edges": edges_out}
