from __future__ import annotations

from uuid import UUID

from sqlalchemy import or_
from sqlmodel import Session, select

from app.core.errors import not_found
from app.features.graph_extend.models import ExtendRequest
from app.features.knowledge_graph.models import Concept, Edge, Graph


def shared_graph(session: Session) -> Graph:
    """The one graph everyone extends."""
    existing = session.exec(select(Graph).where(Graph.slug == "knowledge")).first()
    if existing is not None:
        return existing
    graph = Graph(slug="knowledge", title="Knowledge")
    session.add(graph)
    session.flush()
    return graph


def remove_concept(session: Session, concept_id: UUID) -> dict:
    """Delete one node and the edges that touch it. Other nodes stay."""
    graph = shared_graph(session)
    session.exec(select(Graph).where(Graph.id == graph.id).with_for_update()).one()
    concept = session.get(Concept, concept_id)
    if concept is None or concept.origin_graph_id != graph.id:
        raise not_found("Node not found")
    edges = list(
        session.exec(
            select(Edge).where(
                Edge.graph_id == graph.id,
                or_(Edge.from_concept_id == concept.id, Edge.to_concept_id == concept.id),
            )
        ).all()
    )
    for edge in edges:
        session.delete(edge)
    session.flush()
    requests = session.exec(select(ExtendRequest).where(ExtendRequest.parent_concept_id == concept.id)).all()
    for request in requests:
        request.parent_concept_id = None
    session.delete(concept)
    session.flush()
    return {"concept_id": str(concept_id), "removed_edges": len(edges)}
