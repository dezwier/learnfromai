"""Prefix/substring lookup over existing shared knowledge nodes."""

from __future__ import annotations

from sqlalchemy import func, or_
from sqlmodel import Session, col, select

from app.features.knowledge_graph.identity import canonical_key_for
from app.features.knowledge_graph.node_models import KnowledgeNode


def search_nodes(session: Session, query: str, *, limit: int = 8) -> list[dict]:
    needle = query.strip()
    if not needle:
        return []
    key = canonical_key_for(needle)
    name_pattern = f"%{needle.lower()}%"
    key_pattern = f"%{key}%"
    rows = list(
        session.exec(
            select(KnowledgeNode)
            .where(
                or_(
                    func.lower(KnowledgeNode.name).like(name_pattern),
                    col(KnowledgeNode.name_key).like(key_pattern),
                )
            )
            .order_by(KnowledgeNode.name)
            .limit(max(1, min(limit, 20)))
        ).all()
    )

    def rank(row: KnowledgeNode) -> tuple[int, str]:
        lowered = row.name.lower()
        if row.name_key == key or lowered == needle.lower():
            return (0, row.name.lower())
        if row.name_key.startswith(key) or lowered.startswith(needle.lower()):
            return (1, row.name.lower())
        return (2, row.name.lower())

    rows.sort(key=rank)
    return [
        {
            "id": str(row.id),
            "title": row.name,
            "description": row.description,
            "q": row.q,
            "r": row.r,
            "depth": row.map_depth if row.map_depth is not None else 0,
        }
        for row in rows[:limit]
    ]
