"""Load and enqueue shared tile content (learn / example / check)."""

from __future__ import annotations

from uuid import UUID

from sqlmodel import Session, col, select

from app.core.errors import not_found
from app.features.accounts.models import User
from app.features.content.models import (
    CONTENT_KINDS,
    DEFAULT_BAND,
    RECIPE_VERSION,
    KnowledgeBit,
)
from app.features.knowledge_graph.node_models import KnowledgeNode
from app.features.platform.jobs import enqueue, ensure_watcher
from app.features.platform.models import GenerationJob


def is_content_complete(
    session: Session,
    node_id: UUID,
    *,
    band: str = DEFAULT_BAND,
    recipe_version: int = RECIPE_VERSION,
) -> bool:
    kinds = {
        row.kind
        for row in session.exec(
            select(KnowledgeBit).where(
                KnowledgeBit.node_id == node_id,
                KnowledgeBit.band == band,
                KnowledgeBit.recipe_version == recipe_version,
            )
        ).all()
    }
    return all(kind in kinds for kind in CONTENT_KINDS)


def content_for_node(
    session: Session,
    node_id: UUID,
    *,
    band: str = DEFAULT_BAND,
    recipe_version: int = RECIPE_VERSION,
) -> dict:
    node = session.get(KnowledgeNode, node_id)
    if node is None:
        raise not_found("Topic not found")
    rows = session.exec(
        select(KnowledgeBit)
        .where(
            KnowledgeBit.node_id == node_id,
            KnowledgeBit.band == band,
            KnowledgeBit.recipe_version == recipe_version,
        )
        .order_by(col(KnowledgeBit.position), col(KnowledgeBit.kind))
    ).all()
    bits = [
        {
            "id": str(row.id),
            "kind": row.kind,
            "band": row.band,
            "recipe_version": row.recipe_version,
            "position": row.position,
            "body": row.body if isinstance(row.body, dict) else {},
        }
        for row in rows
    ]
    return {
        "node_id": str(node_id),
        "band": band,
        "recipe_version": recipe_version,
        "incomplete": not is_content_complete(
            session, node_id, band=band, recipe_version=recipe_version
        ),
        "bits": bits,
    }


def enqueue_content_expand(
    session: Session,
    *,
    user: User,
    node_id: UUID,
    band: str = DEFAULT_BAND,
    recipe_version: int = RECIPE_VERSION,
) -> tuple[dict, int]:
    """Return (payload, status). 200 content or 202 job."""
    node = session.get(KnowledgeNode, node_id)
    if node is None:
        raise not_found("Topic not found")
    if is_content_complete(session, node_id, band=band, recipe_version=recipe_version):
        return content_for_node(session, node_id, band=band, recipe_version=recipe_version), 200

    job = _enqueue(session, user=user, node=node, band=band, recipe_version=recipe_version)
    return {
        "status": "queued",
        "job_id": str(job.id),
        "focus_node_id": str(node.id),
        "progress": job.progress
        or {"stage": "queued", "message": "Waiting for a worker…", "fraction": 0},
    }, 202


def content_or_expand(
    session: Session,
    *,
    user: User,
    node_id: UUID,
    expand: bool = False,
    band: str = DEFAULT_BAND,
    recipe_version: int = RECIPE_VERSION,
) -> tuple[dict, int]:
    if not expand:
        return content_for_node(session, node_id, band=band, recipe_version=recipe_version), 200
    return enqueue_content_expand(
        session, user=user, node_id=node_id, band=band, recipe_version=recipe_version
    )


def _enqueue(
    session: Session,
    *,
    user: User,
    node: KnowledgeNode,
    band: str,
    recipe_version: int,
) -> GenerationJob:
    idempotency = f"expand_content:{node.id}:recipe-{recipe_version}:band-{band}"
    job = enqueue(
        session,
        job_type="expand_content",
        user_id=user.id,
        idempotency_key=idempotency,
        shared=True,
        payload={
            "node_id": str(node.id),
            "topic": node.name,
            "requested_by": str(user.id),
            "band": band,
            "recipe_version": recipe_version,
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
