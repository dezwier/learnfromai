from __future__ import annotations

from uuid import UUID

from sqlmodel import Session

from app.core.db import engine
from app.core.errors import AppError
from app.core.time import utcnow
from app.features.graph_extend.models import ExtendRequest
from app.features.platform.jobs import finish
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
    """Graph structure comes from Wikipedia. A leftover expand job must not call a model."""
    _ = (session, job)
    raise AppError("GONE", "Graph generation has been removed", 410, {"terminal": True})


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
