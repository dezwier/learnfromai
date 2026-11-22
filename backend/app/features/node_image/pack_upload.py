"""Accept a user-uploaded image for one learning pack."""

from __future__ import annotations

from uuid import UUID

from sqlmodel import Session

from app.core.errors import AppError, not_found
from app.features.knowledge_graph.node_models import KnowledgeNode
from app.features.node_image.pack_service import image_for_pack, store_pack_image
from app.features.node_image.validate import read_image_upload

MAX_UPLOAD_BYTES = 8 * 1024 * 1024


def upload_pack_image(
    session: Session,
    node_id: UUID,
    pack_index: int,
    *,
    raw: bytes,
    content_type: str | None,
) -> dict:
    node = session.get(KnowledgeNode, node_id)
    if node is None:
        raise not_found("Topic not found")
    if pack_index < 1:
        raise AppError("VALIDATION_ERROR", "pack_index must be >= 1", 422)
    payload = read_image_upload(raw, content_type=content_type, max_bytes=MAX_UPLOAD_BYTES)
    store_pack_image(session, node_id=node_id, pack_index=pack_index, raw=payload)
    return image_for_pack(session, node_id, pack_index)
