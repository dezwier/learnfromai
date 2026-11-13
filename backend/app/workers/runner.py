from __future__ import annotations

import logging
import time

from sqlmodel import Session

from app.core.config import get_settings
from app.core.db import engine
from app.core.errors import AppError
from app.core.time import utcnow
from app.features.platform.jobs import claim_next, retry_later
from app.features.platform.models import WorkerHeartbeat
from app.workers.handlers import handle

logger = logging.getLogger(__name__)


def run_once() -> bool:
    with Session(engine, expire_on_commit=False) as session:
        claimed = claim_next(session)
    if claimed is None:
        return False
    job, token = claimed
    try:
        handle(job.id, token)
    except AppError as exc:
        with Session(engine, expire_on_commit=False) as session:
            retry_later(session, job.id, token, exc.code, exc.message)
        logger.info("job %s failed: %s", job.id, exc.code)
    except Exception as exc:
        with Session(engine, expire_on_commit=False) as session:
            retry_later(session, job.id, token, "GENERATION_UNAVAILABLE", str(exc))
        logger.exception("job %s crashed", job.id)
    return True


def process_until_idle(max_jobs: int = 50) -> int:
    done = 0
    while done < max_jobs and run_once():
        done += 1
    return done


def beat() -> None:
    with Session(engine, expire_on_commit=False) as session:
        row = session.get(WorkerHeartbeat, "worker")
        if row is None:
            session.add(WorkerHeartbeat(id="worker", beat_at=utcnow()))
        else:
            row.beat_at = utcnow()
            session.add(row)
        session.commit()


def run_forever() -> None:
    settings = get_settings()
    logging.basicConfig(level=logging.INFO)
    # One claim per loop; scale parallelism with Railway worker replicas.
    _ = settings.job_worker_concurrency
    while True:
        beat()
        if not run_once():
            time.sleep(settings.job_idle_seconds)
