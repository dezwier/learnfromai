from __future__ import annotations

from uuid import UUID

from sqlalchemy import delete as sql_delete
from sqlalchemy import or_
from sqlalchemy import update as sql_update
from sqlmodel import Session, col, select

from app.core.errors import not_found
from app.core.time import utcnow
from app.features.graph_extend.models import ExtendRequest
from app.features.knowledge_graph.hierarchy import assign_levels
from app.features.knowledge_graph.models import Concept, Edge, Graph
from app.features.platform.models import GenerationJob


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


def remove_request(session: Session, request_id: UUID) -> dict:
    """Delete one extend and the nodes and edges it added.

    A node that already existed, and was only reused, stays. An edge that
    touches a deleted node is removed with that node, including an edge a
    later extend attached to it.
    """
    graph = shared_graph(session)
    session.exec(select(Graph).where(Graph.id == graph.id).with_for_update()).one()
    request = session.get(ExtendRequest, request_id)
    if request is None or request.graph_id != graph.id:
        raise not_found("Extend request not found")
    concepts = list(session.exec(select(Concept).where(Concept.extend_request_id == request_id)).all())
    concept_ids = [concept.id for concept in concepts]
    edge_filter = col(Edge.extend_request_id) == request_id
    if concept_ids:
        edge_filter = or_(
            edge_filter,
            col(Edge.from_concept_id).in_(concept_ids),
            col(Edge.to_concept_id).in_(concept_ids),
        )
    removed_edges = session.exec(sql_delete(Edge).where(edge_filter)).rowcount
    if concept_ids:
        session.exec(
            sql_update(ExtendRequest).where(col(ExtendRequest.parent_concept_id).in_(concept_ids)).values(parent_concept_id=None)
        )
        session.exec(sql_delete(Concept).where(col(Concept.id).in_(concept_ids)))
        for concept in concepts:
            session.expunge(concept)
    if request.job_id is not None:
        job = session.get(GenerationJob, request.job_id)
        if job is not None and job.state in {"queued", "running"}:
            job.state = "failed"
            job.error_code = "CANCELLED"
            job.error_message = "The extend was deleted"
            job.lease_until = None
            job.updated_at = utcnow()
    session.delete(request)
    session.flush()
    remaining = list(session.exec(select(Concept).where(Concept.origin_graph_id == graph.id)).all())
    remaining_edges = list(session.exec(select(Edge).where(Edge.graph_id == graph.id)).all())
    assign_levels(remaining, remaining_edges)
    return {
        "request_id": str(request_id),
        "removed_nodes": len(concept_ids),
        "removed_edges": removed_edges or 0,
    }
