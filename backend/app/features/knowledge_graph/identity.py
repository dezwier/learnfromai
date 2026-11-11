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


_MEDIA_SUFFIXES = (
    "documentary",
    "documentaries",
    "film",
    "films",
    "movie",
    "movies",
    "series",
    "show",
    "shows",
    "album",
    "albums",
    "podcast",
    "podcasts",
    "book",
    "books",
)


def _strip_media_suffix(key: str) -> str:
    """Drop a trailing medium qualifier so a work title matches its titled documentary/film."""
    for suffix in _MEDIA_SUFFIXES:
        token = f"-{suffix}"
        if key.endswith(token) and len(key) > len(token):
            return key[: -len(token)]
    return key


def fold_spelling(key: str) -> str:
    """Collapse common British/American spelling digraphs into one key form.

    palaeontology → paleontology, archaeology → archeology, oestrogen → estrogen.
    """
    return key.replace("ae", "e").replace("oe", "e")


def topic_stems(key: str) -> set[str]:
    """Cheap morphological variants for singular/plural and common taxon endings."""
    stems = {key, _strip_media_suffix(key), fold_spelling(key), fold_spelling(_strip_media_suffix(key))}
    for item in list(stems):
        if item.endswith("ies") and len(item) > 4:
            stems.add(item[:-3] + "y")
        if item.endswith("y") and len(item) > 2:
            stems.add(item[:-1] + "ies")
        if item.endswith("ians") and len(item) > 5:
            # Ornithischians ↔ Ornithischia; also Dinosaurians-style forms.
            base = item[:-4]
            stems.add(item[:-1])  # ...ian
            stems.add(base + "ia")
            stems.add(base)
            stems.add(base + "s")
        if item.endswith("ia") and len(item) > 3:
            # Dinosauria ↔ Dinosaur/Dinosaurs; Ornithischia ↔ Ornithischians.
            base = item[:-2]
            stems.add(base + "ians")
            stems.add(base)
            stems.add(base + "s")
        if item.endswith("s") and len(item) > 2 and not item.endswith("ss"):
            stems.add(item[:-1])
        else:
            stems.add(item + "s")
        stems.add(fold_spelling(item))
    return {stem for stem in stems if stem}


def same_topic(left: str, right: str) -> bool:
    """True when two titles name the same node (plural, taxon, media, or spelling variant)."""
    a = canonical_key_for(left)
    b = canonical_key_for(right)
    if a == b or fold_spelling(a) == fold_spelling(b):
        return True
    return bool(topic_stems(a) & topic_stems(b))


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
