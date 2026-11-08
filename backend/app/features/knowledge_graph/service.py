from __future__ import annotations

from uuid import UUID

from sqlalchemy import delete as sql_delete
from sqlalchemy import or_
from sqlalchemy import update as sql_update
from sqlmodel import Session, col, select

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
    # Delete by endpoint, not by the edge's graph id. An edge can still reference
    # this node after its graph id no longer matches, and the concept delete
    # then fails the foreign key.
    removed_edges = session.exec(
        sql_delete(Edge).where(or_(col(Edge.from_concept_id) == concept_id, col(Edge.to_concept_id) == concept_id))
    ).rowcount
    session.exec(sql_update(ExtendRequest).where(col(ExtendRequest.parent_concept_id) == concept_id).values(parent_concept_id=None))
    session.exec(sql_delete(Concept).where(col(Concept.id) == concept_id))
    session.expunge(concept)
    return {"concept_id": str(concept_id), "removed_edges": removed_edges}


def clear_graph(session: Session) -> dict:
    """Delete every node and every edge. Past extend requests stay."""
    graph = shared_graph(session)
    session.exec(select(Graph).where(Graph.id == graph.id).with_for_update()).one()
    concept_ids = select(Concept.id).where(Concept.origin_graph_id == graph.id)
    session.exec(
        sql_update(ExtendRequest).where(col(ExtendRequest.parent_concept_id).in_(concept_ids)).values(parent_concept_id=None)
    )
    removed_edges = session.exec(
        sql_delete(Edge).where(or_(col(Edge.from_concept_id).in_(concept_ids), col(Edge.to_concept_id).in_(concept_ids)))
    ).rowcount
    removed_nodes = session.exec(sql_delete(Concept).where(col(Concept.origin_graph_id) == graph.id)).rowcount
    return {"removed_nodes": removed_nodes, "removed_edges": removed_edges}
