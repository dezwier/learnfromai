from __future__ import annotations

from sqlmodel import Session, col, select

from app.features.accounts.models import User
from app.features.graph_extend.models import ExtendRequest
from app.features.knowledge_graph.models import Concept, Edge
from app.features.knowledge_graph.service import shared_graph
from app.features.platform.models import GenerationJob


def workspace_graph(session: Session) -> dict:
    """Nodes, edges, and every user's extend requests for the shared graph."""
    graph = shared_graph(session)
    concepts = session.exec(select(Concept).where(Concept.origin_graph_id == graph.id).order_by(Concept.created_at)).all()
    concept_ids = {concept.id for concept in concepts}
    edges = session.exec(select(Edge).where(Edge.graph_id == graph.id).order_by(Edge.created_at)).all()
    requests = session.exec(select(ExtendRequest).where(ExtendRequest.graph_id == graph.id).order_by(ExtendRequest.created_at.desc())).all()
    authors = _authors(session, requests)
    jobs = _jobs(session, requests)
    return {
        "graph_id": str(graph.id),
        "nodes": [
            {
                "concept_id": str(concept.id),
                "title": concept.title,
                "summary": concept.summary,
                "explanation": concept.explanation,
                "level": concept.level,
            }
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
        "extend_requests": [_request_payload(request, authors, jobs) for request in requests],
    }


def _authors(session: Session, requests: list[ExtendRequest]) -> dict:
    if not requests:
        return {}
    user_ids = {request.user_id for request in requests}
    users = session.exec(select(User).where(User.id.in_(user_ids))).all()  # type: ignore[attr-defined]
    return {user.id: user for user in users}


def _jobs(session: Session, requests: list[ExtendRequest]) -> dict:
    job_ids = [request.job_id for request in requests if request.job_id is not None]
    if not job_ids:
        return {}
    rows = session.exec(select(GenerationJob).where(col(GenerationJob.id).in_(job_ids))).all()
    return {row.id: row for row in rows}


def _request_payload(request: ExtendRequest, authors: dict, jobs: dict) -> dict:
    author = authors.get(request.user_id)
    name = None
    if author is not None:
        name = author.display_name or author.email
    job = jobs.get(request.job_id) if request.job_id is not None else None
    progress = job.progress if job is not None and isinstance(job.progress, dict) else {}
    message = progress.get("message")
    if not message and request.status == "queued":
        message = "Waiting to generate"
    if not message and request.status == "running":
        message = "Asking the model"
    return {
        "id": str(request.id),
        "instruction": request.instruction,
        "status": request.status,
        "error_code": request.error_code,
        "error_message": job.error_message if job is not None else None,
        "truncated": request.truncated,
        "parent_concept_id": str(request.parent_concept_id) if request.parent_concept_id else None,
        "job_id": str(request.job_id) if request.job_id else None,
        "progress_stage": progress.get("stage"),
        "progress_message": message,
        "progress_fraction": progress.get("fraction"),
        "created_at": request.created_at.isoformat(),
        "finished_at": request.finished_at.isoformat() if request.finished_at else None,
        "author": name or "Someone",
    }
