"""Daily cron: rank tiles, enqueue shared jobs, persist summary."""

from __future__ import annotations

from uuid import UUID

from sqlmodel import Session, col, select

from app.core.config import Settings, get_settings
from app.core.time import utcnow
from app.features.content.models import DEFAULT_BAND, RECIPE_VERSION
from app.features.knowledge_graph.preferences import min_per_bucket
from app.features.platform.jobs import enqueue
from app.features.platform.models import GenerationJob
from app.features.platform.neighborhood_llm import parse_uuid
from app.features.ranking.affinity import weights_snapshot
from app.features.ranking.job_scores import learn_job_scores, neighbor_job_scores
from app.features.ranking.models import CronRun


def run_daily_cron(session: Session, *, settings: Settings | None = None) -> CronRun:
    """Select top neighbor/learn jobs, enqueue them, return the CronRun row."""
    s = settings or get_settings()
    run = CronRun(
        status="running",
        started_at=utcnow(),
        neighbor_jobs=[],
        learn_jobs=[],
        weights_snapshot=weights_snapshot(s),
    )
    session.add(run)
    session.flush()

    try:
        neighbor_rows = neighbor_job_scores(session, settings=s)[: int(s.cron_neighbor_jobs_per_day)]
        learn_rows = learn_job_scores(session, settings=s)[: int(s.cron_learn_jobs_per_day)]

        neighbor_summary: list[dict] = []
        for row in neighbor_rows:
            job = _enqueue_neighbor(session, row=row, settings=s)
            neighbor_summary.append(
                {
                    "node_id": str(row["node_id"]),
                    "name": row["name"],
                    "tile_affinity": round(float(row["tile_affinity"]), 4),
                    "score": round(float(row["score"]), 4),
                    "neighbor_count": row["neighbor_count"],
                    "fill_factor": round(float(row.get("fill_factor") or 0), 4),
                    "fill_term": round(float(row.get("fill_term") or 0), 4),
                    "job_id": str(job.id) if job is not None else None,
                }
            )

        learn_summary: list[dict] = []
        for row in learn_rows:
            job = _enqueue_learn(session, row=row)
            learn_summary.append(
                {
                    "node_id": str(row["node_id"]),
                    "name": row["name"],
                    "tile_affinity": round(float(row["tile_affinity"]), 4),
                    "score": round(float(row["score"]), 4),
                    "pack_index": row["pack_index"],
                    "pack_count": row["pack_count"],
                    "neighbor_count": row.get("neighbor_count"),
                    "fill_factor": round(float(row.get("fill_factor") or 0), 4),
                    "fill_term": round(float(row.get("fill_term") or 0), 4),
                    "job_id": str(job.id) if job is not None else None,
                }
            )

        run.neighbor_jobs = neighbor_summary
        run.learn_jobs = learn_summary
        run.status = "succeeded"
        run.finished_at = utcnow()
        session.add(run)
        session.flush()
        return run
    except Exception as exc:  # noqa: BLE001 — cron must always persist failure
        run.status = "failed"
        run.error = str(exc)[:2000]
        run.finished_at = utcnow()
        session.add(run)
        session.flush()
        raise


def latest_cron_run(session: Session) -> CronRun | None:
    return session.exec(select(CronRun).order_by(col(CronRun.started_at).desc())).first()


def cron_run_payload(session: Session, run: CronRun) -> dict:
    return {
        "id": str(run.id),
        "status": run.status,
        "started_at": run.started_at.isoformat() if run.started_at else None,
        "finished_at": run.finished_at.isoformat() if run.finished_at else None,
        "neighbor_jobs": _enrich_job_rows(
            session, run.neighbor_jobs or [], job_type="expand_neighborhood"
        ),
        "learn_jobs": _enrich_job_rows(
            session, run.learn_jobs or [], job_type="expand_content"
        ),
        "weights_snapshot": run.weights_snapshot or {},
        "error": run.error,
    }


def cron_queue_preview(session: Session, *, settings: Settings | None = None) -> dict:
    """A-priori ranked neighbor/learn queues (what Run now would enqueue)."""
    s = settings or get_settings()
    neighbor_limit = int(s.cron_neighbor_jobs_per_day)
    learn_limit = int(s.cron_learn_jobs_per_day)
    neighbor_rows = neighbor_job_scores(session, settings=s)[:neighbor_limit]
    learn_rows = learn_job_scores(session, settings=s)[:learn_limit]
    latest = latest_cron_run(session)
    latest_neighbor = {
        str(row.get("node_id")): row
        for row in (latest.neighbor_jobs if latest else []) or []
        if isinstance(row, dict) and row.get("node_id")
    }
    latest_learn = {
        str(row.get("node_id")): row
        for row in (latest.learn_jobs if latest else []) or []
        if isinstance(row, dict) and row.get("node_id")
    }

    def _serialize_neighbor(row: dict) -> dict:
        nid = str(row["node_id"])
        item = {
            "node_id": nid,
            "name": row["name"],
            "tile_affinity": round(float(row["tile_affinity"]), 4),
            "neighbor_count": int(row["neighbor_count"]),
            "fill_factor": round(float(row.get("fill_factor") or 0), 4),
            "fill_term": round(float(row.get("fill_term") or 0), 4),
            "score": round(float(row["score"]), 4),
        }
        prior = latest_neighbor.get(nid)
        if prior and prior.get("job_id"):
            item["job_id"] = prior.get("job_id")
        return item

    def _serialize_learn(row: dict) -> dict:
        nid = str(row["node_id"])
        item = {
            "node_id": nid,
            "name": row["name"],
            "tile_affinity": round(float(row["tile_affinity"]), 4),
            "neighbor_count": int(row.get("neighbor_count") or 0),
            "pack_count": int(row["pack_count"]),
            "pack_index": int(row["pack_index"]),
            "fill_factor": round(float(row.get("fill_factor") or 0), 4),
            "fill_term": round(float(row.get("fill_term") or 0), 4),
            "score": round(float(row["score"]), 4),
        }
        prior = latest_learn.get(nid)
        if prior and prior.get("job_id"):
            item["job_id"] = prior.get("job_id")
        return item

    neighbors = _enrich_job_rows(
        session,
        [_serialize_neighbor(row) for row in neighbor_rows],
        job_type="expand_neighborhood",
    )
    learns = _enrich_job_rows(
        session,
        [_serialize_learn(row) for row in learn_rows],
        job_type="expand_content",
    )
    return {
        "neighbor_jobs": neighbors,
        "learn_jobs": learns,
        "limits": {
            "neighbor_jobs_per_day": neighbor_limit,
            "learn_jobs_per_day": learn_limit,
            "desired_neighbors": int(s.cron_neighbor_budget_total),
            "desired_packs": int(s.cron_learn_desired_packs),
        },
        "latest_run": (
            {
                "id": str(latest.id),
                "status": latest.status,
                "started_at": latest.started_at.isoformat() if latest.started_at else None,
                "finished_at": latest.finished_at.isoformat() if latest.finished_at else None,
            }
            if latest is not None
            else None
        ),
    }


def _enrich_job_rows(
    session: Session, rows: list, *, job_type: str
) -> list[dict]:
    """Attach live job_state / result fields when a job_id is present."""
    out: list[dict] = []
    for row in rows:
        if not isinstance(row, dict):
            continue
        item = dict(row)
        job_id = parse_uuid(item.get("job_id"))
        if job_id is None:
            out.append(item)
            continue
        job = session.get(GenerationJob, job_id)
        if job is None:
            out.append(item)
            continue
        item["job_state"] = job.state
        result = job.result if isinstance(job.result, dict) else {}
        if job_type == "expand_neighborhood" and "neighbors_added" in result:
            try:
                item["neighbors_added"] = int(result["neighbors_added"])
            except (TypeError, ValueError):
                pass
        if job_type == "expand_content":
            payload = job.payload if isinstance(job.payload, dict) else {}
            if item.get("pack_index") is None and payload.get("pack_index") is not None:
                try:
                    item["pack_index"] = int(payload["pack_index"])
                except (TypeError, ValueError):
                    pass
        out.append(item)
    return out


def _enqueue_neighbor(session: Session, *, row: dict, settings: Settings):
    from app.features.platform.jobs import active_job_for_node

    node_id: UUID = row["node_id"]
    user_id: UUID = row["top_user_id"]
    existing = active_job_for_node(
        session, job_type="expand_neighborhood", node_id=node_id
    )
    if existing is not None:
        return existing
    total = int(settings.cron_neighbor_budget_total)
    idempotency = f"expand_neighborhood:{node_id}:total-{total}"
    return enqueue(
        session,
        job_type="expand_neighborhood",
        user_id=user_id,
        idempotency_key=idempotency,
        shared=True,
        payload={
            "focus_id": str(node_id),
            "topic": row["name"],
            "requested_by": str(user_id),
            "total": total,
            "min_per_bucket": min_per_bucket(total),
            "extended": 12,
            "from_existing_focus": True,
            "source": "cron",
        },
    )


def _enqueue_learn(session: Session, *, row: dict):
    from app.features.platform.jobs import active_job_for_node

    node_id: UUID = row["node_id"]
    user_id: UUID = row["top_user_id"]
    existing = active_job_for_node(session, job_type="expand_content", node_id=node_id)
    if existing is not None:
        return existing
    pack_index = int(row["pack_index"])
    missing = list(row["missing_kinds"])
    band = DEFAULT_BAND
    recipe_version = RECIPE_VERSION
    need = "+".join(missing) if missing else "all"
    idempotency = (
        f"expand_content:{node_id}:recipe-{recipe_version}:band-{band}"
        f":pack-{pack_index}:need-{need}"
    )
    return enqueue(
        session,
        job_type="expand_content",
        user_id=user_id,
        idempotency_key=idempotency,
        shared=True,
        payload={
            "node_id": str(node_id),
            "topic": row["name"],
            "requested_by": str(user_id),
            "band": band,
            "recipe_version": recipe_version,
            "pack_index": pack_index,
            "missing_kinds": missing,
            "source": "cron",
        },
    )
