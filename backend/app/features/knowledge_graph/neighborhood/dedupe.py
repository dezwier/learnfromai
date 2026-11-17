"""Collapse near-duplicate knowledge nodes."""

from __future__ import annotations

from uuid import UUID

from sqlmodel import Session, select

from app.features.knowledge_graph.identity import same_topic
from app.features.knowledge_graph.neighborhood.resolve_link import _add_edge
from app.features.knowledge_graph.node_models import (
    KnowledgeEdge,
    KnowledgeNode,
    KnowledgeRequest,
    KnowledgeRequestNode,
)
from app.features.platform.jobs import renew_lease
from app.features.platform.models import GenerationJob

def consolidate_near_duplicates(session: Session, job: GenerationJob | None = None) -> int:
    """Merge existing same_topic nodes into one canonical row. Returns merges performed."""
    rows = list(session.exec(select(KnowledgeNode).order_by(KnowledgeNode.created_at, KnowledgeNode.name)).all())
    if len(rows) < 2:
        return 0
    edge_counts: dict[UUID, int] = {}
    for edge in session.exec(select(KnowledgeEdge)).all():
        edge_counts[edge.from_id] = edge_counts.get(edge.from_id, 0) + 1
        edge_counts[edge.to_id] = edge_counts.get(edge.to_id, 0) + 1

    claimed: set[UUID] = set()
    merges = 0
    for index, keep in enumerate(rows):
        if job is not None and index > 0 and index % 40 == 0:
            renew_lease(session, job)
        if keep.id in claimed:
            continue
        cluster = [keep]
        for other in rows[index + 1 :]:
            if other.id in claimed:
                continue
            if same_topic(keep.name, other.name):
                cluster.append(other)
        if len(cluster) == 1:
            continue
        media_suffixes = (
            "documentary", "documentaries", "film", "films", "movie", "movies",
            "series", "show", "shows", "album", "albums", "podcast", "podcasts", "book", "books",
        )

        def _keeper_score(row: KnowledgeNode) -> tuple:
            from app.features.knowledge_graph.identity import fold_spelling

            media = any(row.name_key.endswith(f"-{suffix}") for suffix in media_suffixes)
            plural = row.name_key.endswith("s") and not row.name_key.endswith(("ss", "us", "is", "ies"))
            # Prefer American/simple spelling (paleontology over palaeontology).
            simple_spelling = 1 if fold_spelling(row.name_key) == row.name_key else 0
            # Canonical title first (no medium suffix), then connectivity / description quality.
            return (
                0 if media else 1,
                simple_spelling,
                1 if plural else 0,
                edge_counts.get(row.id, 0),
                1 if row.description else 0,
                len(row.description or ""),
                -row.created_at.timestamp() if row.created_at else 0,
            )

        keeper = max(cluster, key=_keeper_score)
        for drop in cluster:
            claimed.add(drop.id)
            if drop.id == keeper.id:
                continue
            _merge_node_into(session, keep=keeper, drop=drop)
            merges += 1
            edge_counts[keeper.id] = edge_counts.get(keeper.id, 0) + edge_counts.get(drop.id, 0)
    if merges:
        session.flush()
    return merges


def _merge_node_into(session: Session, *, keep: KnowledgeNode, drop: KnowledgeNode) -> None:
    """Rewire edges/requests from drop onto keep, then delete drop."""
    if keep.id == drop.id:
        return
    if drop.description and not keep.description:
        keep.description = drop.description
        session.add(keep)

    outgoing = list(session.exec(select(KnowledgeEdge).where(KnowledgeEdge.from_id == drop.id)).all())
    incoming = list(session.exec(select(KnowledgeEdge).where(KnowledgeEdge.to_id == drop.id)).all())
    for edge in outgoing + incoming:
        session.delete(edge)
    session.flush()

    for edge in outgoing:
        if edge.to_id == keep.id or edge.to_id == drop.id:
            continue
        _add_edge(session, keep.id, edge.relation, edge.to_id)
    for edge in incoming:
        if edge.from_id == keep.id or edge.from_id == drop.id:
            continue
        _add_edge(session, edge.from_id, edge.relation, keep.id)

    for request in session.exec(select(KnowledgeRequest).where(KnowledgeRequest.focus_id == drop.id)).all():
        request.focus_id = keep.id
        session.add(request)

    drop_rows = list(session.exec(select(KnowledgeRequestNode).where(KnowledgeRequestNode.node_id == drop.id)).all())
    for row in drop_rows:
        request_id = row.request_id
        distance = row.distance
        kind = row.kind
        session.delete(row)
        session.flush()
        exists = session.exec(
            select(KnowledgeRequestNode).where(
                KnowledgeRequestNode.request_id == request_id,
                KnowledgeRequestNode.node_id == keep.id,
            )
        ).first()
        if exists is None:
            session.add(
                KnowledgeRequestNode(
                    request_id=request_id,
                    node_id=keep.id,
                    distance=distance,
                    kind=kind,
                )
            )
            session.flush()
    session.delete(drop)
    session.flush()


