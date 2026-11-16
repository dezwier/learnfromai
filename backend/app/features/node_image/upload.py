"""Accept a user-uploaded image for a topic node."""

from __future__ import annotations

from uuid import UUID

from sqlmodel import Session

from app.core.errors import not_found
from app.features.knowledge_graph.node_models import KnowledgeNode
from app.features.node_image.service import image_for_node, store_generated_image
from app.features.node_image.validate import read_image_upload

# Topic uploads share the same full/thumb pipeline as generated images.
MAX_UPLOAD_BYTES = 8 * 1024 * 1024


def store_uploaded_image(session: Session, node_id: UUID, raw: bytes) -> dict:
    """Replace the node's iconic image with an uploaded file. Returns metadata."""
    node = session.get(KnowledgeNode, node_id)
    if node is None:
        raise not_found("Topic not found")
    store_generated_image(node, raw)
    session.add(node)
    session.flush()
    return image_for_node(session, node_id)


def upload_node_image(session: Session, node_id: UUID, *, raw: bytes, content_type: str | None) -> dict:
    payload = read_image_upload(raw, content_type=content_type, max_bytes=MAX_UPLOAD_BYTES)
    return store_uploaded_image(session, node_id, payload)
