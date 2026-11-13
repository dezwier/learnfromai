from __future__ import annotations

from datetime import timedelta
from uuid import UUID, uuid4

from sqlalchemy import or_
from sqlmodel import Session, col, select

from app.core.config import get_settings
from app.core.errors import AppError
from app.core.time import utcnow
from app.features.platform.models import GenerationJob, GenerationJobWatcher


def enqueue(
    session: Session,
    *,
    job_type: str,
    payload: dict,
    user_id: UUID | None = None,
    idempotency_key: str | None = None,
    shared: bool = False,
) -> GenerationJob:
    """Enqueue a job. When shared=True, coalesce by idempotency_key across all users."""
    settings = get_settings()
    if idempotency_key:
        query = select(GenerationJob).where(GenerationJob.idempotency_key == idempotency_key)
        if not shared:
            if user_id is None:
                query = query.where(GenerationJob.user_id.is_(None))  # type: ignore[union-attr]
            else:
                query = query.where(GenerationJob.user_id == user_id)
        existing = session.exec(query).first()
        # Reuse in-flight work only. Terminal jobs must not block a fresh expand.
        if existing is not None and existing.state in {"queued", "running"}:
            return existing
        if existing is not None and existing.state not in {"queued", "running"}:
            # Free the key so a new row can use it (unique index may not exist; still keep one logical key).
            existing.idempotency_key = f"{idempotency_key}:done:{existing.id}"
            session.add(existing)
            session.flush()
    # Shared expands use user_id=None so the system unique key enforces one active expand.
    job = GenerationJob(
        user_id=None if shared else user_id,
        type=job_type,
        payload=payload,
        idempotency_key=idempotency_key,
        max_attempts=settings.job_max_attempts,
        progress={"stage": "queued", "message": "Waiting for a worker…", "fraction": 0},
    )
    session.add(job)
    session.flush()
    return job


def ensure_watcher(
    session: Session,
    *,
    job: GenerationJob,
    user_id: UUID,
    node_id: UUID,
    title: str,
) -> GenerationJobWatcher:
    existing = session.exec(
        select(GenerationJobWatcher).where(
            GenerationJobWatcher.job_id == job.id,
            GenerationJobWatcher.user_id == user_id,
        )
    ).first()
    if existing is not None:
        if title and existing.title != title:
            existing.title = title[:512]
            session.add(existing)
        return existing
    row = GenerationJobWatcher(
        job_id=job.id,
        user_id=user_id,
        node_id=node_id,
        title=(title or "")[:512],
    )
    session.add(row)
    session.flush()
    return row


def user_watches_job(session: Session, *, job_id: UUID, user_id: UUID) -> bool:
    return (
        session.exec(
            select(GenerationJobWatcher.id).where(
                GenerationJobWatcher.job_id == job_id,
                GenerationJobWatcher.user_id == user_id,
            )
        ).first()
        is not None
    )


def list_watched_jobs(
    session: Session,
    *,
    user_id: UUID,
    states: set[str] | None = None,
) -> list[dict]:
    active = states or {"queued", "running"}
    rows = session.exec(
        select(GenerationJobWatcher, GenerationJob)
        .join(GenerationJob, GenerationJob.id == GenerationJobWatcher.job_id)
        .where(GenerationJobWatcher.user_id == user_id)
        .where(col(GenerationJob.state).in_(sorted(active)))
        .order_by(col(GenerationJobWatcher.created_at).desc())
    ).all()
    out: list[dict] = []
    for watcher, job in rows:
        progress = job.progress if isinstance(job.progress, dict) else {}
        focus_id = (job.payload or {}).get("focus_id") or str(watcher.node_id)
        out.append(
            {
                "id": str(job.id),
                "type": job.type,
                "state": job.state,
                "progress": progress,
                "focus_node_id": str(focus_id),
                "title": watcher.title or (job.payload or {}).get("topic") or "Topic",
                "created_at": watcher.created_at.isoformat() if watcher.created_at else None,
                "error_code": job.error_code,
                "error_message": job.error_message,
            }
        )
    return out


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


def renew_lease(session: Session, job: GenerationJob) -> None:
    """Extend the running lease so long LLM/consolidate work is not reclaimed mid-flight.

    Jobs invoked without a worker claim (tests) have no lease_token; those still commit.
    Always re-read the row before writing so a stale in-memory token cannot overwrite
    a lease another worker already stole.
    """
    settings = get_settings()
    token = job.lease_token
    progress = job.progress
    payload = job.payload
    job_id = job.id
    if token is None:
        job.updated_at = utcnow()
        session.add(job)
        session.commit()
        return
    session.expire(job)
    fresh = session.get(GenerationJob, job_id)
    if fresh is None or fresh.lease_token != token or fresh.state != "running":
        raise AppError("JOB_LEASE_LOST", "Job lease was taken by another worker", 409)
    fresh.progress = progress
    fresh.payload = payload
    fresh.lease_until = utcnow() + timedelta(seconds=settings.job_lease_seconds)
    fresh.updated_at = utcnow()
    session.add(fresh)
    session.commit()
    session.refresh(fresh)
    job.progress = fresh.progress
    job.payload = fresh.payload
    job.lease_until = fresh.lease_until
    job.lease_token = fresh.lease_token
    job.updated_at = fresh.updated_at
    job.state = fresh.state


def finish(session: Session, job_id: UUID, token: UUID, result: dict) -> bool:
    job = session.get(GenerationJob, job_id)
    if job is None or job.state != "running" or job.lease_token != token:
        return False
    job.state = "succeeded"
    job.result = result
    job.error_code = None
    job.lease_until = None
    if job.idempotency_key:
        job.idempotency_key = f"{job.idempotency_key}:done:{job.id}"
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
        job.progress = {
            "stage": "failed",
            "message": "Could not generate related topics",
            "fraction": 1.0,
        }
    else:
        # Space retries so the UI does not thrash Resolving↔Asking every few seconds.
        delay = min(300, max(20, 15 * (2 ** max(0, job.attempts - 1))))
        job.state = "queued"
        job.lease_until = utcnow() + timedelta(seconds=delay)
        job.progress = {
            "stage": "retry",
            "message": f"Model hiccup — retrying in about {delay}s…",
            "fraction": 0.12,
        }
    session.commit()
