from __future__ import annotations

import re
from uuid import UUID

from sqlmodel import Session, select

from app.features.knowledge_graph.models import Concept


def canonical_key_for(title: str) -> str:
    cleaned = "".join(char.lower() if char.isalnum() else "-" for char in title.strip())
    while "--" in cleaned:
        cleaned = cleaned.replace("--", "-")
    return cleaned.strip("-") or "topic"


def is_placeholder_title(title: str, titles: set[str] | None = None) -> bool:
    """Labels such as 'Topic structure' are not subjects."""
    folded = title.strip().lower()
    if folded in {"topic", "topic structure", "topic origins"}:
        return True
    if folded.endswith(" practice"):
        return True
    known = {item.strip().lower() for item in titles} if titles is not None else None
    for suffix in (" structure", " origins"):
        if not folded.endswith(suffix):
            continue
        stem = folded[: -len(suffix)].strip()
        if known is None or stem in known:
            return True
    return False


def same_topic(left: str, right: str) -> bool:
    """True when two titles name the same node, including a trailing plural."""
    a = canonical_key_for(left)
    b = canonical_key_for(right)
    if a == b:
        return True
    return (a.endswith("s") and a[:-1] == b) or (b.endswith("s") and b[:-1] == a)


def explanation_covers(explanation: str, title: str) -> bool:
    """True when the title is already inside the range an explanation describes."""
    phrase = re.sub(r"\s+", " ", title.strip().lower())
    if len(phrase) < 4:
        return False
    haystack = re.sub(r"\s+", " ", explanation.lower())
    return re.search(rf"(?<![a-z0-9]){re.escape(phrase)}(?![a-z0-9])", haystack) is not None


def neighborhood(session: Session, graph_id: UUID, limit: int = 400) -> list[dict]:
    """Recent nodes the generator should reuse instead of copying."""
    rows = session.exec(
        select(Concept).where(Concept.origin_graph_id == graph_id).order_by(Concept.created_at.desc()).limit(limit)
    ).all()
    return [
        {
            "concept_id": str(row.id),
            "title": row.title,
            "canonical_key": row.canonical_key or canonical_key_for(row.title),
            "level": row.level,
            "summary": row.summary,
            "explanation": (row.explanation or "")[:600],
        }
        for row in rows
    ]
