"""Edit and delete shared knowledge nodes."""

from __future__ import annotations

from uuid import UUID

from sqlmodel import Session, col, or_, select

from app.core.errors import not_found
from app.features.knowledge_graph.identity import canonical_key_for
from app.features.knowledge_graph.node_models import (
    KnowledgeEdge,
    KnowledgeNode,
    KnowledgeRequest,
    KnowledgeRequestNode,
)


def update_knowledge_node(
    session: Session,
    node_id: UUID,
    *,
    name: str | None = None,
    description: str | None = None,
) -> dict:
    row = session.get(KnowledgeNode, node_id)
    if row is None:
        raise not_found("Topic not found")
    if name is not None:
        cleaned = name.strip()
        if not cleaned:
            from app.core.errors import AppError

            raise AppError("VALIDATION_ERROR", "Name cannot be empty", 422)
        row.name = cleaned
        row.name_key = canonical_key_for(cleaned)
    if description is not None:
        text = description.strip()
        row.description = text or None
    session.add(row)
    session.flush()
    return {
        "id": str(row.id),
        "title": row.name,
        "description": row.description,
        "image_url": row.image_url,
    }


def delete_knowledge_node(session: Session, node_id: UUID) -> dict:
    row = session.get(KnowledgeNode, node_id)
    if row is None:
        raise not_found("Topic not found")

    edges = list(
        session.exec(
            select(KnowledgeEdge).where(
                or_(col(KnowledgeEdge.from_id) == node_id, col(KnowledgeEdge.to_id) == node_id)
            )
        ).all()
    )
    for edge in edges:
        session.delete(edge)
    session.flush()

    for link in list(session.exec(select(KnowledgeRequestNode).where(KnowledgeRequestNode.node_id == node_id)).all()):
        session.delete(link)
    session.flush()

    focused = list(session.exec(select(KnowledgeRequest).where(KnowledgeRequest.focus_id == node_id)).all())
    for request in focused:
        for link in list(
            session.exec(select(KnowledgeRequestNode).where(KnowledgeRequestNode.request_id == request.id)).all()
        ):
            session.delete(link)
        session.delete(request)
    session.flush()

    title = row.name
    session.delete(row)
    session.flush()
    return {"id": str(node_id), "title": title, "deleted": True, "edges_removed": len(edges)}
