"""Load or enqueue an LLM neighborhood for a topic focus."""

from __future__ import annotations

from uuid import UUID

from sqlmodel import Session, col, select

from app.features.accounts.models import User
from app.features.knowledge_graph.neighborhood import (
    build_subgraph,
    ensure_focus_node,
    is_complete,
)
from app.features.knowledge_graph.node_models import KnowledgeRequest
from app.features.knowledge_graph.preferences import neighborhood_counts
from app.features.platform.jobs import enqueue, ensure_watcher
from app.features.platform.models import GenerationJob
from app.features.platform.neighborhood_llm import parse_uuid


def focus_or_enqueue(
    session: Session,
    *,
    user: User,
    topic: str | None = None,
    node_id: UUID | None = None,
    expand: bool = False,
) -> tuple[dict, int]:
    """Return (payload, status). 200 graph or 202 job.

    Opening / searching / resuming only loads the current neighborhood.
    Expand jobs run only when ``expand`` is true (Request neighbors).
    """
    counts = neighborhood_counts(user)
    if (topic is None or not str(topic).strip()) and node_id is None:
        return _resume(session, user=user)

    focus = ensure_focus_node(session, topic=topic, node_id=node_id)
    session.flush()
    if is_complete(session, focus.id, counts):
        return _graph_payload(session, user=user, focus=focus, counts=counts), 200

    if not expand:
        return _graph_payload(session, user=user, focus=focus, counts=counts), 200

    job = _enqueue_expand(session, user=user, focus=focus, topic=topic, counts=counts)
    return {
        "status": "queued",
        "job_id": str(job.id),
        "focus_node_id": str(focus.id),
        "progress": job.progress or {"stage": "queued", "message": "Waiting for a worker…", "fraction": 0},
    }, 202


def graph_for_focus(session: Session, *, user: User, focus_id: UUID) -> dict:
    focus = ensure_focus_node(session, node_id=focus_id)
    counts = neighborhood_counts(user)
    return _graph_payload(session, user=user, focus=focus, counts=counts)


def _graph_payload(session: Session, *, user: User, focus, counts: dict[str, int]) -> dict:
    payload = build_subgraph(
        session, focus, max_extended=counts["extended"], counts=counts
    )
    request = KnowledgeRequest(
        user_id=user.id,
        focus_id=focus.id,
        parents=int(counts.get("total") or 16),
        siblings=int(counts.get("min_per_bucket") or 2),
        children=0,
        acquaintances=0,
    )
    session.add(request)
    session.flush()
    payload["request_id"] = str(request.id)
    return payload


def _resume(session: Session, *, user: User) -> tuple[dict, int]:
    latest = session.exec(
        select(KnowledgeRequest).where(KnowledgeRequest.user_id == user.id).order_by(col(KnowledgeRequest.created_at).desc())
    ).first()
    if latest is None:
        return {"focus_node_id": None, "incomplete": False, "request_id": None, "nodes": [], "edges": []}, 200
    # Never auto top-up on resume — show whatever neighbors already exist.
    return graph_for_focus(session, user=user, focus_id=latest.focus_id), 200


def _enqueue_expand(
    session: Session,
    *,
    user: User,
    focus,
    topic: str | None,
    counts: dict[str, int],
) -> GenerationJob:
    # One shared expand per focus+total budget across all users (shared graph).
    idempotency = f"expand_neighborhood:{focus.id}:total-{counts['total']}"
    job = enqueue(
        session,
        job_type="expand_neighborhood",
        user_id=user.id,
        idempotency_key=idempotency,
        shared=True,
        payload={
            "focus_id": str(focus.id),
            "topic": topic or focus.name,
            "requested_by": str(user.id),
            "total": counts["total"],
            "min_per_bucket": counts.get("min_per_bucket", 2),
            "extended": counts.get("extended", 12),
        },
    )
    ensure_watcher(
        session,
        job=job,
        user_id=user.id,
        node_id=focus.id,
        title=focus.name,
    )
    return job


# Compatibility for older imports/tests.
def load_knowledge_graph(session: Session, **kwargs):
    user = kwargs.get("user")
    if user is None:
        user_id = kwargs.get("user_id")
        user = session.get(User, user_id) if user_id else None
    if user is None:
        from app.core.errors import AppError

        raise AppError("UNAUTHORIZED", "User required", 401)
    node_id = kwargs.get("node_id") or parse_uuid(kwargs.get("focus_qid"))
    payload, _status = focus_or_enqueue(
        session,
        user=user,
        topic=kwargs.get("topic"),
        node_id=node_id,
    )
    return payload
