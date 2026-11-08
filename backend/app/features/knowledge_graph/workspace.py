from __future__ import annotations

from sqlmodel import Session, select

from app.features.accounts.models import User
from app.features.graph_extend.models import ExtendRequest
from app.features.knowledge_graph.models import Concept, Edge
from app.features.knowledge_graph.service import shared_graph


def workspace_graph(session: Session) -> dict:
    """Nodes, edges, and every user's extend requests for the shared graph."""
    graph = shared_graph(session)
    concepts = session.exec(select(Concept).where(Concept.origin_graph_id == graph.id).order_by(Concept.created_at)).all()
    concept_ids = {concept.id for concept in concepts}
    edges = session.exec(select(Edge).where(Edge.graph_id == graph.id).order_by(Edge.created_at)).all()
    requests = session.exec(select(ExtendRequest).where(ExtendRequest.graph_id == graph.id).order_by(ExtendRequest.created_at.desc())).all()
    authors = _authors(session, requests)
    return {
        "graph_id": str(graph.id),
        "nodes": [
            {"concept_id": str(concept.id), "title": concept.title, "summary": concept.summary}
            for concept in concepts
        ],
        "edges": [
            {
                "edge_id": str(edge.id),
                "from_concept_id": str(edge.from_concept_id),
                "to_concept_id": str(edge.to_concept_id),
                "type": edge.type,
            }
            for edge in edges
            if edge.from_concept_id in concept_ids and edge.to_concept_id in concept_ids
        ],
        "extend_requests": [_request_payload(request, authors) for request in requests],
    }


def _authors(session: Session, requests: list[ExtendRequest]) -> dict:
    if not requests:
        return {}
    user_ids = {request.user_id for request in requests}
    users = session.exec(select(User).where(User.id.in_(user_ids))).all()  # type: ignore[attr-defined]
    return {user.id: user for user in users}


def _request_payload(request: ExtendRequest, authors: dict) -> dict:
    author = authors.get(request.user_id)
    name = None
    if author is not None:
        name = author.display_name or author.email
    return {
        "id": str(request.id),
        "instruction": request.instruction,
        "status": request.status,
        "error_code": request.error_code,
        "truncated": request.truncated,
        "parent_concept_id": str(request.parent_concept_id) if request.parent_concept_id else None,
        "created_at": request.created_at.isoformat(),
        "finished_at": request.finished_at.isoformat() if request.finished_at else None,
        "author": name or "Someone",
    }
