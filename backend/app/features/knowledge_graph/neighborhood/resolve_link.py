"""Focus resolve, sameness match, and edge linking."""

from __future__ import annotations

from uuid import UUID

from sqlalchemy import func, or_
from sqlalchemy.orm import load_only
from sqlmodel import Session, col, select

from app.features.knowledge_graph.identity import canonical_key_for, same_topic, topic_stems
from app.features.knowledge_graph.neighborhood.constants import (
    BUCKET_RELATION,
    INVERSE,
    NEAR_CANDIDATE_LIMIT,
    set_progress,
)
from app.features.knowledge_graph.node_models import KnowledgeEdge, KnowledgeNode
from app.features.platform.llm import assert_user_quota, maybe_record_usage
from app.features.platform.models import GenerationJob
from app.features.platform.neighborhood_llm import BUCKETS, parse_uuid

def ensure_focus_node(session: Session, *, topic: str | None = None, node_id: UUID | None = None) -> KnowledgeNode:
    if node_id is not None:
        # Graph/refocus never needs image BLOBs — only name/description/url path.
        row = session.exec(
            select(KnowledgeNode)
            .where(KnowledgeNode.id == node_id)
            .options(
                load_only(
                    KnowledgeNode.id,
                    KnowledgeNode.name,
                    KnowledgeNode.name_key,
                    KnowledgeNode.description,
                    KnowledgeNode.image_url,
                    KnowledgeNode.created_at,
                )
            )
        ).first()
        if row is None:
            from app.core.errors import not_found

            raise not_found("Topic not found")
        return row
    name = (topic or "").strip()
    if not name:
        from app.core.errors import AppError

        raise AppError("VALIDATION_ERROR", "Provide a topic or a node_id", 422)
    key = canonical_key_for(name)
    existing = list(session.exec(select(KnowledgeNode).where(KnowledgeNode.name_key == key)).all())
    if len(existing) == 1:
        return existing[0]
    if existing:
        # Prefer exact display-name match before creating another collision.
        for row in existing:
            if row.name.lower() == name.lower():
                return row
        return existing[0]
    near = _near_name_candidates(session, name)
    for row in near:
        if same_topic(row.name, name):
            return row
    row = KnowledgeNode(name=name[:1].upper() + name[1:] if name else name, name_key=key, description=None)
    session.add(row)
    session.flush()
    return row


def _near_name_candidates(
    session: Session, name: str, *, limit: int = NEAR_CANDIDATE_LIMIT
) -> list[KnowledgeNode]:
    """Existing nodes whose titles look close enough to ask sameness / same_topic."""
    needle = name.strip()
    if not needle:
        return []
    key = canonical_key_for(needle)
    capped = max(1, min(limit, NEAR_CANDIDATE_LIMIT))
    clauses = [
        func.lower(KnowledgeNode.name).like(f"%{needle.lower()}%"),
        col(KnowledgeNode.name_key).like(f"%{key}%"),
    ]
    # Morph stems (dinosaur from Dinosauria, the-last-dance from …Documentary).
    for stem in sorted(topic_stems(key), key=len, reverse=True)[:8]:
        if len(stem) < 4:
            continue
        clauses.append(col(KnowledgeNode.name_key).like(f"%{stem}%"))
        clauses.append(func.lower(KnowledgeNode.name).like(f"%{stem.replace('-', ' ')}%"))
    rows = list(
        session.exec(
            select(KnowledgeNode)
            .where(or_(*clauses))
            .order_by(KnowledgeNode.name)
            .limit(capped)
        ).all()
    )
    # Prefer exact / same_topic hits first for stable merges.
    rows.sort(
        key=lambda row: (
            0 if row.name_key == key or same_topic(row.name, needle) else 1,
            abs(len(row.name_key) - len(key)),
            row.name.lower(),
        )
    )
    return rows[:capped]


def _pack_existing(rows: list[KnowledgeNode]) -> list[dict]:
    """Name+description payload for sameness prompts."""
    return [
        {"id": str(row.id), "name": row.name, "description": row.description}
        for row in rows
    ]


def _bucket_items(neighborhood: dict) -> list[tuple[str, dict]]:
    items: list[tuple[str, dict]] = []
    for bucket in BUCKETS:
        for item in neighborhood.get(bucket) or []:
            if isinstance(item, dict):
                items.append((bucket, item))
    return items


def _resolve_local(
    session: Session,
    *,
    name: str,
    description: str | None,
    preferred: KnowledgeNode | None = None,
) -> tuple[KnowledgeNode | None, list[KnowledgeNode]]:
    """Deterministic resolve. Returns (node_or_none, near_candidates_for_llm)."""
    key = canonical_key_for(name)
    desc = description
    existing = list(session.exec(select(KnowledgeNode).where(KnowledgeNode.name_key == key)).all())
    if preferred is not None and (preferred.name_key == key or same_topic(preferred.name, name)):
        if desc and not preferred.description:
            preferred.description = desc
            preferred.name = name
            session.add(preferred)
            session.flush()
        return preferred, []
    if len(existing) == 1 and (
        not desc
        or not existing[0].description
        or existing[0].description == desc
        or preferred is not None
    ):
        row = existing[0]
        if desc and (not row.description or preferred is not None):
            row.description = desc or row.description
            row.name = name
            session.add(row)
            session.flush()
        return row, []

    near = list(existing)
    seen_ids = {row.id for row in near}
    for row in _near_name_candidates(session, name, limit=NEAR_CANDIDATE_LIMIT):
        if row.id in seen_ids:
            continue
        near.append(row)
        seen_ids.add(row.id)
    near = near[:NEAR_CANDIDATE_LIMIT]

    # Morphological / spelling / media near-duplicates share a concept. Exact same
    # name_key with differing descriptions can still be true homonyms (Bass fish
    # vs Bass pitch), so those go through the LLM sameness check.
    for row in near:
        if row.name_key != key and same_topic(row.name, name):
            if desc and not row.description:
                row.description = desc
                session.add(row)
                session.flush()
            return row, []

    return None, near


def _create_named(session: Session, *, name: str, description: str | None) -> KnowledgeNode:
    row = KnowledgeNode(name=name, name_key=canonical_key_for(name), description=description)
    session.add(row)
    session.flush()
    return row


def _apply_match(
    session: Session,
    *,
    name: str,
    description: str | None,
    chosen_id: UUID | None,
) -> KnowledgeNode:
    if chosen_id is not None:
        row = session.get(KnowledgeNode, chosen_id)
        if row is not None:
            if description and not row.description:
                row.description = description
                session.add(row)
                session.flush()
            return row
    return _create_named(session, name=name, description=description)


def _match_topics_batch(
    session: Session,
    *,
    llm,
    user_id: UUID,
    job_id: UUID | None,
    pending: list[dict],
) -> dict[str, UUID | None]:
    """One cheap LLM sameness call for all unresolved titles. Returns key -> id|None."""
    if not pending:
        return {}
    assert_user_quota(session, user_id)
    setattr(llm, "usage_task", "sameness")
    candidates = [
        {
            "key": str(item["key"]),
            "name": str(item["name"]),
            "description": item.get("description"),
            "existing": item["existing"],
        }
        for item in pending
    ]
    matched, usage = llm.match_topics(candidates)
    maybe_record_usage(
        session, llm, user_id=user_id, job_id=job_id, task="sameness", usage=usage
    )
    session.flush()
    assert_user_quota(session, user_id)
    raw = matched.get("matches") if isinstance(matched, dict) else {}
    if not isinstance(raw, dict):
        raw = {}
    return {str(key): parse_uuid(value) for key, value in raw.items()}


def _link_resolved_batch(
    session: Session,
    *,
    job: GenerationJob,
    llm,
    user_id: UUID,
    focus: KnowledgeNode,
    bucket_items: list[tuple[str, dict]],
    linked: dict[str, list[UUID]],
    seen_names: set[str],
    seen_titles: list[str],
    progress_start: float,
    progress_span: float,
) -> None:
    """Resolve titles with same_topic first, then one batched match_topics call."""
    ready: list[tuple[str, KnowledgeNode, str]] = []
    pending: list[dict] = []
    total = len(bucket_items) or 1
    scanned = 0

    for bucket, item in bucket_items:
        scanned += 1
        name = str(item.get("name") or "").strip()
        if not name:
            continue
        key = canonical_key_for(name)
        if key in seen_names or any(same_topic(name, prior) for prior in seen_titles):
            continue
        desc = str(item.get("description") or "").strip() or None
        seen_names.add(key)
        seen_titles.append(name)
        set_progress(
            session,
            job,
            stage="merge",
            message=f"Merging {name}…",
            fraction=progress_start + progress_span * (scanned / total) * 0.5,
        )
        node, near = _resolve_local(session, name=name, description=desc)
        if node is not None:
            ready.append((bucket, node, name))
            continue
        if not near:
            ready.append((bucket, _create_named(session, name=name, description=desc), name))
            continue
        pending.append(
            {
                "key": f"p{len(pending)}",
                "bucket": bucket,
                "name": name,
                "description": desc,
                "existing": _pack_existing(near),
            }
        )

    matches = _match_topics_batch(
        session, llm=llm, user_id=user_id, job_id=job.id, pending=pending
    )
    for item in pending:
        node = _apply_match(
            session,
            name=str(item["name"]),
            description=item.get("description"),
            chosen_id=matches.get(str(item["key"])),
        )
        ready.append((str(item["bucket"]), node, str(item["name"])))

    for index, (bucket, node, name) in enumerate(ready):
        relation = BUCKET_RELATION[bucket]
        if node.id == focus.id or node.id in linked[bucket]:
            continue
        set_progress(
            session,
            job,
            stage="merge",
            message=f"Linking {name}…",
            fraction=progress_start + progress_span * (0.5 + 0.5 * ((index + 1) / max(len(ready), 1))),
        )
        _ensure_pair(session, focus.id, node.id, relation)
        linked[bucket].append(node.id)
    session.commit()


def _upsert_named(
    session: Session,
    *,
    llm,
    user_id: UUID,
    job_id: UUID | None,
    name: str,
    description: object,
    preferred: KnowledgeNode | None = None,
) -> KnowledgeNode:
    desc = str(description).strip() if description else None
    node, near = _resolve_local(session, name=name, description=desc, preferred=preferred)
    if node is not None:
        return node
    if not near:
        return _create_named(session, name=name, description=desc)
    matches = _match_topics_batch(
        session,
        llm=llm,
        user_id=user_id,
        job_id=job_id,
        pending=[
            {
                "key": "c0",
                "name": name,
                "description": desc,
                "existing": _pack_existing(near),
            }
        ],
    )
    return _apply_match(session, name=name, description=desc, chosen_id=matches.get("c0"))


def _ensure_pair(session: Session, focus_id: UUID, other_id: UUID, relation: str) -> None:
    if focus_id == other_id:
        return
    inverse = INVERSE[relation]
    _add_edge(session, focus_id, relation, other_id)
    _add_edge(session, other_id, inverse, focus_id)


def _add_edge(session: Session, from_id: UUID, relation: str, to_id: UUID) -> None:
    existing = session.get(KnowledgeEdge, (from_id, relation, to_id))
    if existing is not None:
        return
    session.add(KnowledgeEdge(from_id=from_id, relation=relation, to_id=to_id))


