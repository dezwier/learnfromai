from __future__ import annotations

from uuid import UUID

from sqlmodel import Session

from app.core.db import engine
from app.core.errors import AppError
from app.core.time import utcnow
from app.features.content.generate import expand_content
from app.features.knowledge_graph.neighborhood import expand_neighborhood
from app.features.node_image.generate import generate_image
from app.features.node_image.pack_generate import generate_pack_image
from app.features.platform.jobs import finish
from app.features.platform.models import GenerationJob, WorkerHeartbeat


def handle(job_id: UUID, token: UUID) -> None:
    with Session(engine, expire_on_commit=False) as session:
        job = session.get(GenerationJob, job_id)
        if job is None:
            return
        dispatch = {
            "noop": _noop,
            "expand_neighborhood": _expand_neighborhood,
            "expand_content": _expand_content,
            "generate_image": _generate_image,
            "generate_pack_image": _generate_pack_image,
        }
        fn = dispatch.get(job.type)
        if fn is None:
            raise AppError("NOT_FOUND", f"Unknown job type {job.type}", 404)
        try:
            result = fn(session, job)
        except Exception as exc:
            session.rollback()
            if isinstance(exc, AppError) and exc.details.get("terminal"):
                fresh = session.get(GenerationJob, job_id)
                if fresh is not None and fresh.attempts < fresh.max_attempts:
                    fresh.attempts = fresh.max_attempts
                    session.commit()
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


def _expand_neighborhood(session: Session, job: GenerationJob) -> dict:
    return expand_neighborhood(session, job)


def _expand_content(session: Session, job: GenerationJob) -> dict:
    return expand_content(session, job)


def _generate_image(session: Session, job: GenerationJob) -> dict:
    return generate_image(session, job)


def _generate_pack_image(session: Session, job: GenerationJob) -> dict:
    return generate_pack_image(session, job)
