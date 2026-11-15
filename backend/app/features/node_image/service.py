"""Load and enqueue shared node image generation."""

from __future__ import annotations

from uuid import UUID

from sqlmodel import Session

from app.core.errors import not_found
from app.features.accounts.models import User
from app.features.knowledge_graph.node_models import KnowledgeNode
from app.features.platform.jobs import enqueue, ensure_watcher
from app.features.platform.models import GenerationJob


def image_path_for(node_id: UUID) -> str:
    return f"/knowledge/nodes/{node_id}/image/file"


def has_image(node: KnowledgeNode) -> bool:
    return bool(node.image_bytes) or bool(node.image_url)


def image_for_node(session: Session, node_id: UUID) -> dict:
    node = session.get(KnowledgeNode, node_id)
    if node is None:
        raise not_found("Topic not found")
    incomplete = not has_image(node)
    return {
        "node_id": str(node_id),
        "image_url": node.image_url if not incomplete else None,
        "incomplete": incomplete,
    }


def image_bytes_for_node(session: Session, node_id: UUID) -> bytes:
    node = session.get(KnowledgeNode, node_id)
    if node is None or not node.image_bytes:
        raise not_found("Topic image not found")
    return bytes(node.image_bytes)


def enqueue_image_generate(
    session: Session,
    *,
    user: User,
    node_id: UUID,
    regenerate: bool = False,
) -> tuple[dict, int]:
    """Return (payload, status). 200 metadata or 202 job."""
    node = session.get(KnowledgeNode, node_id)
    if node is None:
        raise not_found("Topic not found")
    if has_image(node) and not regenerate:
        return image_for_node(session, node_id), 200

    job = _enqueue(session, user=user, node=node, regenerate=regenerate)
    return {
        "status": "queued",
        "job_id": str(job.id),
        "focus_node_id": str(node.id),
        "progress": job.progress
        or {"stage": "queued", "message": "Waiting for a worker…", "fraction": 0},
    }, 202


def image_or_generate(
    session: Session,
    *,
    user: User,
    node_id: UUID,
    generate: bool = False,
    regenerate: bool = False,
) -> tuple[dict, int]:
    if regenerate:
        return enqueue_image_generate(session, user=user, node_id=node_id, regenerate=True)
    if generate:
        return enqueue_image_generate(session, user=user, node_id=node_id, regenerate=False)
    return image_for_node(session, node_id), 200


def _enqueue(
    session: Session,
    *,
    user: User,
    node: KnowledgeNode,
    regenerate: bool,
) -> GenerationJob:
    idempotency = f"generate_image:{node.id}"
    job = enqueue(
        session,
        job_type="generate_image",
        user_id=user.id,
        idempotency_key=idempotency,
        shared=True,
        payload={
            "node_id": str(node.id),
            "topic": node.name,
            "requested_by": str(user.id),
            "regenerate": regenerate,
        },
    )
    ensure_watcher(
        session,
        job=job,
        user_id=user.id,
        node_id=node.id,
        title=node.name,
    )
    return job
