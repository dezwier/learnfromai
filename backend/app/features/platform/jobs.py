from __future__ import annotations

from datetime import timedelta
from uuid import UUID, uuid4

from sqlalchemy import or_
from sqlmodel import Session, select

from app.core.config import get_settings
from app.core.time import utcnow
from app.features.platform.models import GenerationJob


def enqueue(
    session: Session,
    *,
    job_type: str,
    payload: dict,
    user_id: UUID | None = None,
    idempotency_key: str | None = None,
) -> GenerationJob:
    settings = get_settings()
    if idempotency_key:
        query = select(GenerationJob).where(GenerationJob.idempotency_key == idempotency_key)
        if user_id is None:
            query = query.where(GenerationJob.user_id.is_(None))  # type: ignore[union-attr]
        else:
            query = query.where(GenerationJob.user_id == user_id)
        existing = session.exec(query).first()
        if existing is not None:
            return existing
    job = GenerationJob(
        user_id=user_id,
        type=job_type,
        payload=payload,
        idempotency_key=idempotency_key,
        max_attempts=settings.job_max_attempts,
    )
    session.add(job)
    session.flush()
    return job


def claim_next(session: Session) -> tuple[GenerationJob, UUID] | None:
    settings = get_settings()
    for _ in range(5):
        now = utcnow()
        query = (
            select(GenerationJob)
            .where(
                or_(
                    GenerationJob.state == "queued",
                    GenerationJob.state == "running",
                )
            )
            .where(or_(GenerationJob.lease_until.is_(None), GenerationJob.lease_until < now))  # type: ignore[union-attr]
            .order_by(GenerationJob.created_at)
            .limit(1)
            .with_for_update(skip_locked=True)
        )
        job = session.exec(query).first()
        if job is None:
            return None
        if job.attempts >= job.max_attempts:
            job.state = "failed"
            job.error_code = "POISON"
            job.lease_until = None
            job.updated_at = now
            session.commit()
            continue
        token = uuid4()
        job.state = "running"
        job.attempts += 1
        job.lease_token = token
        job.lease_until = now + timedelta(seconds=settings.job_lease_seconds)
        job.updated_at = now
        session.commit()
        return job, token
    return None


def finish(session: Session, job_id: UUID, token: UUID, result: dict) -> bool:
    job = session.get(GenerationJob, job_id)
    if job is None or job.state != "running" or job.lease_token != token:
        return False
    job.state = "succeeded"
    job.result = result
    job.error_code = None
    job.lease_until = None
    job.updated_at = utcnow()
    session.commit()
    return True


def retry_later(session: Session, job_id: UUID, token: UUID, code: str, message: str) -> None:
    job = session.get(GenerationJob, job_id)
    if job is None or job.lease_token != token or job.state != "running":
        return
    job.error_code = code
    job.error_message = message[:500]
    job.updated_at = utcnow()
    if job.attempts >= job.max_attempts:
        job.state = "failed"
        job.lease_until = None
    else:
        job.state = "queued"
        job.lease_until = utcnow() + timedelta(seconds=min(300, 2**job.attempts))
    session.commit()
