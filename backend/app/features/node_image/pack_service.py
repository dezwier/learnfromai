"""Load and enqueue shared pack-level images."""

from __future__ import annotations

from uuid import UUID

from sqlmodel import Session, col, select

from app.core.errors import AppError, not_found
from app.features.accounts.models import User
from app.features.content.models import DEFAULT_BAND, RECIPE_VERSION, KnowledgeBit
from app.features.knowledge_graph.node_models import KnowledgeNode
from app.features.node_image.pack_models import KnowledgePackImage
from app.features.node_image.resize import prepare_node_images
from app.features.node_image.service import has_image as node_has_image
from app.features.node_image.service import image_path_for as node_image_path_for
from app.features.node_image.service import thumb_path_for as node_thumb_path_for
from app.features.platform.jobs import (
    ACTIVE_JOB_STATES,
    enqueue,
    ensure_watcher,
)
from app.features.platform.models import GenerationJob


def pack_image_path_for(node_id: UUID, pack_index: int, *, variant: str = "full") -> str:
    base = f"/knowledge/nodes/{node_id}/packs/{pack_index}/image/file"
    if variant == "thumb":
        return f"{base}?variant=thumb"
    return base


def pack_thumb_path_for(node_id: UUID, pack_index: int) -> str:
    return pack_image_path_for(node_id, pack_index, variant="thumb")


def get_pack_image(
    session: Session,
    node_id: UUID,
    pack_index: int,
) -> KnowledgePackImage | None:
    return session.exec(
        select(KnowledgePackImage).where(
            KnowledgePackImage.node_id == node_id,
            KnowledgePackImage.pack_index == pack_index,
        )
    ).first()


def has_pack_image(row: KnowledgePackImage | None) -> bool:
    if row is None:
        return False
    return bool(row.image_bytes) or bool(row.image_url)


def image_for_pack(session: Session, node_id: UUID, pack_index: int) -> dict:
    node = session.get(KnowledgeNode, node_id)
    if node is None:
        raise not_found("Topic not found")
    if pack_index < 1:
        raise AppError("VALIDATION_ERROR", "pack_index must be >= 1", 422)
    row = get_pack_image(session, node_id, pack_index)
    incomplete = not has_pack_image(row)
    return {
        "node_id": str(node_id),
        "pack_index": pack_index,
        "image_url": pack_image_path_for(node_id, pack_index) if not incomplete else None,
        "image_thumb_url": pack_thumb_path_for(node_id, pack_index) if not incomplete else None,
        "incomplete": incomplete,
    }


def image_bytes_for_pack(
    session: Session,
    node_id: UUID,
    pack_index: int,
    *,
    variant: str = "full",
) -> tuple[bytes, str]:
    row = get_pack_image(session, node_id, pack_index)
    if row is None or not row.image_bytes:
        raise not_found("Atom image not found")
    if variant == "thumb":
        if not row.image_thumb_bytes:
            _, thumb = prepare_node_images(bytes(row.image_bytes))
            row.image_thumb_bytes = thumb
            session.add(row)
            session.flush()
        return bytes(row.image_thumb_bytes), "image/jpeg"
    return bytes(row.image_bytes), "image/png"


def store_pack_image(
    session: Session,
    *,
    node_id: UUID,
    pack_index: int,
    raw: bytes,
) -> KnowledgePackImage:
    full, thumb = prepare_node_images(raw)
    row = get_pack_image(session, node_id, pack_index)
    if row is None:
        row = KnowledgePackImage(node_id=node_id, pack_index=pack_index)
    row.image_bytes = full
    row.image_thumb_bytes = thumb
    row.image_url = pack_image_path_for(node_id, pack_index)
    session.add(row)
    session.flush()
    return row


def delete_pack_image(session: Session, *, node_id: UUID, pack_index: int) -> int:
    row = get_pack_image(session, node_id, pack_index)
    if row is None:
        return 0
    session.delete(row)
    session.flush()
    return 1


def pack_image_fields(
    session: Session,
    node: KnowledgeNode,
    pack_index: int | None,
) -> dict[str, str | None]:
    """Effective card image (pack override else topic) plus optional pack-only URLs."""
    topic_full = node_image_path_for(node.id) if node_has_image(node) else None
    topic_thumb = node_thumb_path_for(node.id) if node_has_image(node) else None
    pack_full = None
    pack_thumb = None
    if pack_index is not None and pack_index >= 1:
        row = get_pack_image(session, node.id, pack_index)
        if has_pack_image(row):
            pack_full = pack_image_path_for(node.id, pack_index)
            pack_thumb = pack_thumb_path_for(node.id, pack_index)
    return {
        "image_url": pack_full or topic_full,
        "image_thumb_url": pack_thumb or topic_thumb,
        "pack_image_url": pack_full,
        "pack_image_thumb_url": pack_thumb,
    }


def learn_bit_text(
    session: Session,
    node_id: UUID,
    pack_index: int,
    *,
    band: str = DEFAULT_BAND,
    recipe_version: int = RECIPE_VERSION,
) -> tuple[str, str]:
    """Return (title, markdown) for the pack's learn bit."""
    row = session.exec(
        select(KnowledgeBit).where(
            KnowledgeBit.node_id == node_id,
            KnowledgeBit.pack_index == pack_index,
            KnowledgeBit.kind == "learn",
            KnowledgeBit.band == band,
            KnowledgeBit.recipe_version == recipe_version,
        )
    ).first()
    if row is None:
        raise not_found("Atom learn bit not found")
    body = row.body if isinstance(row.body, dict) else {}
    title = str(body.get("title") or "").strip()
    markdown = str(body.get("markdown") or "").strip()
    if not title and not markdown:
        raise AppError("VALIDATION_ERROR", "Atom learn bit is empty", 422, {"terminal": True})
    return title, markdown


def enqueue_pack_image_generate(
    session: Session,
    *,
    user: User,
    node_id: UUID,
    pack_index: int,
    regenerate: bool = False,
) -> tuple[dict, int]:
    node = session.get(KnowledgeNode, node_id)
    if node is None:
        raise not_found("Topic not found")
    if pack_index < 1:
        raise AppError("VALIDATION_ERROR", "pack_index must be >= 1", 422)
    # Ensure learn bit exists before enqueueing.
    learn_bit_text(session, node_id, pack_index)
    if has_pack_image(get_pack_image(session, node_id, pack_index)) and not regenerate:
        return image_for_pack(session, node_id, pack_index), 200

    job = _enqueue(session, user=user, node=node, pack_index=pack_index, regenerate=regenerate)
    return {
        "status": "queued",
        "job_id": str(job.id),
        "focus_node_id": str(node.id),
        "pack_index": pack_index,
        "type": "generate_pack_image",
        "progress": job.progress
        or {"stage": "queued", "message": "Waiting for a worker…", "fraction": 0},
    }, 202


def pack_image_or_generate(
    session: Session,
    *,
    user: User,
    node_id: UUID,
    pack_index: int,
    generate: bool = False,
    regenerate: bool = False,
) -> tuple[dict, int]:
    if regenerate:
        return enqueue_pack_image_generate(
            session, user=user, node_id=node_id, pack_index=pack_index, regenerate=True
        )
    if generate:
        return enqueue_pack_image_generate(
            session, user=user, node_id=node_id, pack_index=pack_index, regenerate=False
        )
    return image_for_pack(session, node_id, pack_index), 200


def active_pack_image_jobs(session: Session, node_id: UUID) -> list[GenerationJob]:
    """All in-flight pack-image jobs for a node (any pack_index)."""
    nid = str(node_id)
    rows = session.exec(
        select(GenerationJob)
        .where(GenerationJob.type == "generate_pack_image")
        .where(col(GenerationJob.state).in_(sorted(ACTIVE_JOB_STATES)))
        .order_by(col(GenerationJob.created_at).desc())
    ).all()
    out: list[GenerationJob] = []
    for job in rows:
        payload = job.payload or {}
        if payload.get("node_id") == nid:
            out.append(job)
    return out


def active_pack_image_job(
    session: Session,
    *,
    node_id: UUID,
    pack_index: int,
) -> GenerationJob | None:
    for job in active_pack_image_jobs(session, node_id):
        payload = job.payload or {}
        try:
            if int(payload.get("pack_index") or 0) == pack_index:
                return job
        except (TypeError, ValueError):
            continue
    return None


def _enqueue(
    session: Session,
    *,
    user: User,
    node: KnowledgeNode,
    pack_index: int,
    regenerate: bool,
) -> GenerationJob:
    existing = active_pack_image_job(session, node_id=node.id, pack_index=pack_index)
    if existing is not None:
        ensure_watcher(
            session,
            job=existing,
            user_id=user.id,
            node_id=node.id,
            title=node.name,
        )
        return existing

    idempotency = f"generate_pack_image:{node.id}:{pack_index}"
    job = enqueue(
        session,
        job_type="generate_pack_image",
        user_id=user.id,
        idempotency_key=idempotency,
        shared=True,
        payload={
            "node_id": str(node.id),
            "pack_index": pack_index,
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
