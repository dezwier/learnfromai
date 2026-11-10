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
from app.features.platform.jobs import enqueue
from app.features.platform.models import GenerationJob
from app.features.platform.neighborhood_llm import parse_uuid


def focus_or_enqueue(
    session: Session,
    *,
    user: User,
    topic: str | None = None,
    node_id: UUID | None = None,
) -> tuple[dict, int]:
    """Return (payload, status). 200 graph or 202 job."""
    counts = neighborhood_counts(user)
    if (topic is None or not str(topic).strip()) and node_id is None:
        return _resume(session, user=user, counts=counts)

    focus = ensure_focus_node(session, topic=topic, node_id=node_id)
    session.flush()
    if is_complete(session, focus.id, counts):
        payload = build_subgraph(session, focus)
        request = KnowledgeRequest(
            user_id=user.id,
            focus_id=focus.id,
            parents=counts["parents"],
            siblings=counts["siblings"],
            children=counts["children"],
            acquaintances=counts["acquaintances"],
        )
        session.add(request)
        session.flush()
        payload["request_id"] = str(request.id)
        return payload, 200

    job = _enqueue_expand(session, user=user, focus=focus, topic=topic, counts=counts)
    return {
        "status": "queued",
        "job_id": str(job.id),
        "focus_node_id": str(focus.id),
        "progress": job.progress or {"stage": "queued", "message": "Waiting for a worker…", "fraction": 0},
    }, 202


def graph_for_focus(session: Session, *, user: User, focus_id: UUID) -> dict:
    focus = ensure_focus_node(session, node_id=focus_id)
    payload = build_subgraph(session, focus)
    counts = neighborhood_counts(user)
    request = KnowledgeRequest(
        user_id=user.id,
        focus_id=focus.id,
        parents=counts["parents"],
        siblings=counts["siblings"],
        children=counts["children"],
        acquaintances=counts["acquaintances"],
    )
    session.add(request)
    session.flush()
    payload["request_id"] = str(request.id)
    return payload


def _resume(session: Session, *, user: User, counts: dict[str, int]) -> tuple[dict, int]:
    latest = session.exec(
        select(KnowledgeRequest).where(KnowledgeRequest.user_id == user.id).order_by(col(KnowledgeRequest.created_at).desc())
    ).first()
    if latest is None:
        return {"focus_node_id": None, "incomplete": False, "request_id": None, "nodes": [], "edges": []}, 200
    return focus_or_enqueue(session, user=user, topic=None, node_id=latest.focus_id)


def _enqueue_expand(
    session: Session,
    *,
    user: User,
    focus,
    topic: str | None,
    counts: dict[str, int],
) -> GenerationJob:
    # Reuse an in-flight job for the same focus + counts.
    idempotency = (
        f"expand_neighborhood:{focus.id}:"
        f"{counts['parents']}-{counts['siblings']}-{counts['children']}-{counts['acquaintances']}"
    )
    existing = session.exec(
        select(GenerationJob).where(
            GenerationJob.user_id == user.id,
            GenerationJob.idempotency_key == idempotency,
            col(GenerationJob.state).in_(["queued", "running"]),
        )
    ).first()
    if existing is not None:
        return existing
    return enqueue(
        session,
        job_type="expand_neighborhood",
        user_id=user.id,
        idempotency_key=idempotency,
        payload={
            "focus_id": str(focus.id),
            "topic": topic or focus.name,
            **counts,
        },
    )


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
