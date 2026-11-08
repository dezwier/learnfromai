from __future__ import annotations

from datetime import timedelta
from uuid import UUID

from sqlmodel import Session, select

from app.core.config import get_settings
from app.core.db import engine
from app.core.errors import AppError
from app.core.time import utcnow
from app.features.accounts.models import User
from app.features.graph_extend.models import ExtendRequest
from app.features.graph_extend.service import apply_branch
from app.features.knowledge_graph.identity import neighborhood
from app.features.knowledge_graph.models import Concept, Graph
from app.features.platform.jobs import finish
from app.features.platform.llm import assert_user_quota, get_provider, record_usage
from app.features.platform.models import GenerationJob, WorkerHeartbeat


def handle(job_id: UUID, token: UUID) -> None:
    with Session(engine, expire_on_commit=False) as session:
        job = session.get(GenerationJob, job_id)
        if job is None:
            return
        dispatch = {
            "noop": _noop,
            "expand_graph": _expand_graph,
        }
        fn = dispatch.get(job.type)
        if fn is None:
            raise AppError("NOT_FOUND", f"Unknown job type {job.type}", 404)
        try:
            result = fn(session, job)
        except Exception as exc:
            session.rollback()
            code = exc.code if isinstance(exc, AppError) else "GENERATION_UNAVAILABLE"
            if isinstance(exc, AppError) and exc.details.get("terminal"):
                fresh = session.get(GenerationJob, job_id)
                if fresh is not None and fresh.attempts < fresh.max_attempts:
                    fresh.attempts = fresh.max_attempts
                    session.commit()
            _fail_request(job_id, code)
            raise
        finish(session, job_id, token, result)


def _noop(session: Session, job: GenerationJob) -> dict:
    beat = session.get(WorkerHeartbeat, "worker")
    if beat is None:
        session.add(WorkerHeartbeat(id="worker", beat_at=utcnow()))
    else:
        beat.beat_at = utcnow()
        session.add(beat)
    session.commit()
    return {"ok": True, "payload": job.payload}


def _expand_graph(session: Session, job: GenerationJob) -> dict:
    payload = job.payload
    request = session.get(ExtendRequest, UUID(payload["request_id"]))
    if request is None:
        raise AppError("NOT_FOUND", "Extend request missing", 404)
    user = session.get(User, job.user_id) if job.user_id else None
    if user is None:
        raise AppError("NOT_FOUND", "User missing", 404)
    graph = session.get(Graph, request.graph_id)
    if graph is None:
        raise AppError("NOT_FOUND", "Graph missing", 404)
    parent = session.get(Concept, request.parent_concept_id) if request.parent_concept_id else None
    if request.parent_concept_id is not None and (parent is None or parent.origin_graph_id != graph.id):
        raise AppError("NOT_FOUND", "Parent concept is not in the graph", 404)
    assert_user_quota(session, user.id)
    _progress(session, job, request, "asking", "Asking the model", 0.55)

    provider = get_provider()
    branch, usage = provider.propose_graph_branch(
        {
            "instruction": request.instruction,
            "parent_concept_id": str(parent.id) if parent else None,
            "parent_title": parent.title if parent else None,
            "parent_level": parent.level if parent else None,
            "parent_explanation": parent.explanation if parent else None,
            "existing": neighborhood(session, graph.id),
            "max_new_concepts": get_settings().graph_expansion_max_nodes,
        }
    )
    record_usage(session, user_id=user.id, job_id=job.id, task="propose_graph_branch", provider=provider.name, usage=usage)
    session.exec(select(Graph).where(Graph.id == graph.id).with_for_update()).one()
    session.expire(job)
    session.expire(request)
    session.refresh(job)
    request = session.get(ExtendRequest, UUID(payload["request_id"]))
    if job.state == "failed" or request is None:
        session.commit()
        return {"added_nodes": 0, "added_edges": 0, "truncated": False}
    _progress(session, job, request, "merging", "Adding topics to the graph", 0.85)
    result = apply_branch(
        session,
        graph=graph,
        parent_concept_id=parent.id if parent else None,
        branch=branch,
        instruction=request.instruction,
        extend_request_id=request.id,
    )
    session.expire(request)
    request = session.get(ExtendRequest, UUID(payload["request_id"]))
    if request is None:
        session.commit()
        return result
    request.status = "succeeded"
    request.error_code = None
    request.truncated = bool(result["truncated"])
    request.finished_at = utcnow()
    _progress(session, job, request, "done", "Generation finished", 1)
    return result


def _progress(session: Session, job: GenerationJob, request: ExtendRequest, stage: str, message: str, fraction: float) -> None:
    job.progress = {"stage": stage, "message": message, "fraction": fraction}
    job.updated_at = utcnow()
    if stage not in {"done", "failed"}:
        job.lease_until = utcnow() + timedelta(seconds=max(get_settings().job_lease_seconds, 180))
    if request.status not in {"succeeded", "failed"}:
        request.status = "queued" if stage == "queued" else "running"
    session.commit()


def _fail_request(job_id: UUID, code: str) -> None:
    with Session(engine, expire_on_commit=False) as session:
        job = session.get(GenerationJob, job_id)
        if job is None or job.type != "expand_graph":
            return
        if job.attempts < job.max_attempts:
            return
        request_id = (job.payload or {}).get("request_id")
        if not request_id:
            return
        request = session.get(ExtendRequest, UUID(str(request_id)))
        if request is None or request.status in {"succeeded", "failed"}:
            return
        request.status = "failed"
        request.error_code = code
        request.finished_at = utcnow()
        session.commit()
