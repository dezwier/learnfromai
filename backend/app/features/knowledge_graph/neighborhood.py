"""Shared LLM neighborhood expand + merge into one knowledge universe."""

from __future__ import annotations

from collections import deque
from uuid import UUID

from sqlalchemy import func, or_
from sqlmodel import Session, col, select

from app.features.knowledge_graph.identity import canonical_key_for, same_topic, topic_stems
from app.features.knowledge_graph.node_models import (
    KnowledgeEdge,
    KnowledgeNode,
    KnowledgeRequest,
    KnowledgeRequestNode,
)
from app.features.platform.jobs import renew_lease
from app.features.platform.llm import assert_user_quota, record_usage
from app.features.platform.models import GenerationJob
from app.features.platform.neighborhood_llm import BUCKETS, get_neighborhood_llm, parse_uuid

RELATION_PARENT = "parent"
RELATION_CHILD = "child"
RELATION_SIBLING = "sibling"
RELATION_ACQUAINTANCE = "acquaintance"

BUCKET_RELATION = {
    "parents": RELATION_PARENT,
    "siblings": RELATION_SIBLING,
    "children": RELATION_CHILD,
    "acquaintances": RELATION_ACQUAINTANCE,
}

INVERSE = {
    RELATION_PARENT: RELATION_CHILD,
    RELATION_CHILD: RELATION_PARENT,
    RELATION_SIBLING: RELATION_SIBLING,
    RELATION_ACQUAINTANCE: RELATION_ACQUAINTANCE,
}

KIND_FOR_RELATION = {
    RELATION_PARENT: "parent",
    RELATION_CHILD: "child",
    RELATION_SIBLING: "sibling",
    RELATION_ACQUAINTANCE: "related",
}

# Cap how many close existing rows we send into one sameness prompt.
NEAR_CANDIDATE_LIMIT = 16


def relation_counts(session: Session, focus_id: UUID) -> dict[str, int]:
    edges = list(session.exec(select(KnowledgeEdge).where(KnowledgeEdge.from_id == focus_id)).all())
    counts = {key: 0 for key in BUCKET_RELATION}
    for edge in edges:
        for bucket, relation in BUCKET_RELATION.items():
            if edge.relation == relation:
                counts[bucket] += 1
    return counts


def is_complete(session: Session, focus_id: UUID, counts: dict[str, int]) -> bool:
    have = relation_counts(session, focus_id)
    return all(have.get(bucket, 0) >= int(counts.get(bucket, 0)) for bucket in BUCKET_RELATION)


def ensure_focus_node(session: Session, *, topic: str | None = None, node_id: UUID | None = None) -> KnowledgeNode:
    if node_id is not None:
        row = session.get(KnowledgeNode, node_id)
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


def set_progress(session: Session, job: GenerationJob, *, stage: str, message: str, fraction: float) -> None:
    job.progress = {"stage": stage, "message": message, "fraction": max(0.0, min(1.0, fraction))}
    # Renew while reporting progress so a second worker cannot restart the same job mid-flight.
    renew_lease(session, job)


def expand_neighborhood(session: Session, job: GenerationJob) -> dict:
    payload = job.payload or {}
    user_id = job.user_id or parse_uuid(payload.get("requested_by"))
    if user_id is None:
        from app.features.platform.models import GenerationJobWatcher

        watcher = session.exec(
            select(GenerationJobWatcher).where(GenerationJobWatcher.job_id == job.id)
        ).first()
        if watcher is not None:
            user_id = watcher.user_id
    if user_id is None:
        from app.core.errors import AppError

        raise AppError("VALIDATION_ERROR", "Job is missing a user", 422)
    assert_user_quota(session, user_id)
    counts = {
        "parents": int(payload.get("parents") or 2),
        "siblings": int(payload.get("siblings") or 3),
        "children": int(payload.get("children") or 4),
        "acquaintances": int(payload.get("acquaintances") or 4),
    }
    focus_id = parse_uuid(payload.get("focus_id"))
    topic = str(payload.get("topic") or "").strip() or None
    if int(job.attempts or 0) > 1:
        set_progress(
            session,
            job,
            stage="resolve",
            message=f"Retrying neighborhood (attempt {job.attempts})…",
            fraction=0.05,
        )
    else:
        set_progress(session, job, stage="resolve", message="Resolving topic…", fraction=0.05)
    # Collapse leftover near-duplicates from earlier generations before linking more.
    consolidate_near_duplicates(session, job=job)
    session.commit()
    renew_lease(session, job)
    # Consolidate may have deleted focus_id; fall back to topic lookup for the keeper.
    focus = session.get(KnowledgeNode, focus_id) if focus_id is not None else None
    if focus is None:
        focus = ensure_focus_node(session, topic=topic, node_id=None)
    # Focus id may have moved if this topic was merged into a canonical node.
    if focus_id is not None and focus.id != focus_id:
        job.payload = {**(job.payload or {}), "focus_id": str(focus.id)}
        session.add(job)
    session.commit()

    if is_complete(session, focus.id, counts):
        set_progress(session, job, stage="done", message="Neighborhood already complete", fraction=1.0)
        request = _persist_request(session, user_id=user_id, focus=focus, counts=counts, job_id=job.id)
        session.commit()
        return {"focus_id": str(focus.id), "request_id": str(request.id), "skipped": True}

    llm = get_neighborhood_llm()
    # Keep the lease alive across Gemini attempt timeouts (each can take ~60s).
    setattr(llm, "heartbeat", lambda: renew_lease(session, job))
    set_progress(session, job, stage="generate", message="Asking the model for related topics…", fraction=0.15)
    neighborhood, usage = llm.generate_neighborhood(focus.name if not topic else topic, counts)
    renew_lease(session, job)
    record_usage(session, user_id=user_id, job_id=job.id, task="neighborhood", provider=llm.name, usage=usage)
    session.commit()

    focus_spec = neighborhood.get("focus") if isinstance(neighborhood.get("focus"), dict) else {}
    if focus_spec.get("name") or focus_spec.get("description"):
        focus = _upsert_named(
            session,
            llm=llm,
            user_id=user_id,
            job_id=job.id,
            name=str(focus_spec.get("name") or focus.name),
            description=focus_spec.get("description"),
            preferred=focus,
        )
        session.commit()

    set_progress(session, job, stage="merge", message="Merging topics into the shared graph…", fraction=0.35)
    linked: dict[str, list[UUID]] = {bucket: [] for bucket in BUCKETS}
    seen_names: set[str] = {canonical_key_for(focus.name)}
    seen_titles: list[str] = [focus.name]
    _link_resolved_batch(
        session,
        job=job,
        llm=llm,
        user_id=user_id,
        focus=focus,
        bucket_items=_bucket_items(neighborhood),
        linked=linked,
        seen_names=seen_names,
        seen_titles=seen_titles,
        progress_start=0.35,
        progress_span=0.45,
    )

    # Fill short buckets with a repair pass once.
    short = {bucket: max(0, counts[bucket] - len(linked[bucket])) for bucket in BUCKETS if len(linked[bucket]) < counts[bucket]}
    if any(short.values()):
        set_progress(session, job, stage="repair", message="Filling missing related topics…", fraction=0.85)
        repair_counts = {bucket: short.get(bucket, 0) for bucket in BUCKETS}
        repair, repair_usage = llm.generate_neighborhood(focus.name, repair_counts)
        renew_lease(session, job)
        record_usage(
            session, user_id=user_id, job_id=job.id, task="neighborhood_repair", provider=llm.name, usage=repair_usage
        )
        repair_items = []
        for bucket in BUCKETS:
            need = short.get(bucket, 0)
            if need <= 0:
                continue
            for item in (repair.get(bucket) or [])[:need]:
                if isinstance(item, dict):
                    repair_items.append((bucket, item))
        _link_resolved_batch(
            session,
            job=job,
            llm=llm,
            user_id=user_id,
            focus=focus,
            bucket_items=repair_items,
            linked=linked,
            seen_names=seen_names,
            seen_titles=seen_titles,
            progress_start=0.85,
            progress_span=0.08,
        )

    set_progress(session, job, stage="persist", message="Saving neighborhood…", fraction=0.95)
    request = _persist_request(session, user_id=user_id, focus=focus, counts=counts, job_id=job.id)
    set_progress(session, job, stage="done", message="Neighborhood ready", fraction=1.0)
    session.commit()
    return {"focus_id": str(focus.id), "request_id": str(request.id), "skipped": False}


def consolidate_near_duplicates(session: Session, job: GenerationJob | None = None) -> int:
    """Merge existing same_topic nodes into one canonical row. Returns merges performed."""
    rows = list(session.exec(select(KnowledgeNode).order_by(KnowledgeNode.created_at, KnowledgeNode.name)).all())
    if len(rows) < 2:
        return 0
    edge_counts: dict[UUID, int] = {}
    for edge in session.exec(select(KnowledgeEdge)).all():
        edge_counts[edge.from_id] = edge_counts.get(edge.from_id, 0) + 1
        edge_counts[edge.to_id] = edge_counts.get(edge.to_id, 0) + 1

    claimed: set[UUID] = set()
    merges = 0
    for index, keep in enumerate(rows):
        if job is not None and index > 0 and index % 40 == 0:
            renew_lease(session, job)
        if keep.id in claimed:
            continue
        cluster = [keep]
        for other in rows[index + 1 :]:
            if other.id in claimed:
                continue
            if same_topic(keep.name, other.name):
                cluster.append(other)
        if len(cluster) == 1:
            continue
        media_suffixes = (
            "documentary", "documentaries", "film", "films", "movie", "movies",
            "series", "show", "shows", "album", "albums", "podcast", "podcasts", "book", "books",
        )

        def _keeper_score(row: KnowledgeNode) -> tuple:
            from app.features.knowledge_graph.identity import fold_spelling

            media = any(row.name_key.endswith(f"-{suffix}") for suffix in media_suffixes)
            plural = row.name_key.endswith("s") and not row.name_key.endswith(("ss", "us", "is", "ies"))
            # Prefer American/simple spelling (paleontology over palaeontology).
            simple_spelling = 1 if fold_spelling(row.name_key) == row.name_key else 0
            # Canonical title first (no medium suffix), then connectivity / description quality.
            return (
                0 if media else 1,
                simple_spelling,
                1 if plural else 0,
                edge_counts.get(row.id, 0),
                1 if row.description else 0,
                len(row.description or ""),
                -row.created_at.timestamp() if row.created_at else 0,
            )

        keeper = max(cluster, key=_keeper_score)
        for drop in cluster:
            claimed.add(drop.id)
            if drop.id == keeper.id:
                continue
            _merge_node_into(session, keep=keeper, drop=drop)
            merges += 1
            edge_counts[keeper.id] = edge_counts.get(keeper.id, 0) + edge_counts.get(drop.id, 0)
    if merges:
        session.flush()
    return merges


def _merge_node_into(session: Session, *, keep: KnowledgeNode, drop: KnowledgeNode) -> None:
    """Rewire edges/requests from drop onto keep, then delete drop."""
    if keep.id == drop.id:
        return
    if drop.description and not keep.description:
        keep.description = drop.description
        session.add(keep)

    outgoing = list(session.exec(select(KnowledgeEdge).where(KnowledgeEdge.from_id == drop.id)).all())
    incoming = list(session.exec(select(KnowledgeEdge).where(KnowledgeEdge.to_id == drop.id)).all())
    for edge in outgoing + incoming:
        session.delete(edge)
    session.flush()

    for edge in outgoing:
        if edge.to_id == keep.id or edge.to_id == drop.id:
            continue
        _add_edge(session, keep.id, edge.relation, edge.to_id)
    for edge in incoming:
        if edge.from_id == keep.id or edge.from_id == drop.id:
            continue
        _add_edge(session, edge.from_id, edge.relation, keep.id)

    for request in session.exec(select(KnowledgeRequest).where(KnowledgeRequest.focus_id == drop.id)).all():
        request.focus_id = keep.id
        session.add(request)

    drop_rows = list(session.exec(select(KnowledgeRequestNode).where(KnowledgeRequestNode.node_id == drop.id)).all())
    for row in drop_rows:
        request_id = row.request_id
        distance = row.distance
        kind = row.kind
        session.delete(row)
        session.flush()
        exists = session.exec(
            select(KnowledgeRequestNode).where(
                KnowledgeRequestNode.request_id == request_id,
                KnowledgeRequestNode.node_id == keep.id,
            )
        ).first()
        if exists is None:
            session.add(
                KnowledgeRequestNode(
                    request_id=request_id,
                    node_id=keep.id,
                    distance=distance,
                    kind=kind,
                )
            )
            session.flush()
    session.delete(drop)
    session.flush()


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
    record_usage(session, user_id=user_id, job_id=job_id, task="sameness", provider=llm.name, usage=usage)
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


def _persist_request(
    session: Session,
    *,
    user_id: UUID,
    focus: KnowledgeNode,
    counts: dict[str, int],
    job_id: UUID | None,
) -> KnowledgeRequest:
    payload = build_subgraph(
        session,
        focus,
        max_extended=int(counts.get("extended") or 12),
        counts=counts,
    )
    request = KnowledgeRequest(
        user_id=user_id,
        focus_id=focus.id,
        parents=counts["parents"],
        siblings=counts["siblings"],
        children=counts["children"],
        acquaintances=counts["acquaintances"],
        job_id=job_id,
    )
    session.add(request)
    session.flush()
    for node in payload["nodes"]:
        session.add(
            KnowledgeRequestNode(
                request_id=request.id,
                node_id=UUID(str(node["id"])),
                distance=int(node["distance"]),
                kind=str(node["kind"]),
            )
        )
    session.flush()
    return request


def build_subgraph(
    session: Session,
    focus: KnowledgeNode,
    *,
    max_extended: int = 36,
    counts: dict[str, int] | None = None,
) -> dict:
    """Direct neighborhood first, then unique neighbors-of-neighbors as `extended`."""
    kinds: dict[UUID, str] = {focus.id: "focus"}
    depths: dict[UUID, int] = {focus.id: 0}
    nodes: dict[UUID, KnowledgeNode] = {focus.id: focus}

    for edge in session.exec(select(KnowledgeEdge).where(KnowledgeEdge.from_id == focus.id)).all():
        other = session.get(KnowledgeNode, edge.to_id)
        if other is None:
            continue
        # Hide near-duplicates of the focus (Dinosaur beside Dinosaurs, etc.).
        if same_topic(other.name, focus.name):
            continue
        # Keep one title per near-duplicate cluster among directs.
        if any(same_topic(other.name, prior.name) for prior in nodes.values() if prior.id != focus.id):
            continue
        nodes[other.id] = other
        kind = KIND_FOR_RELATION.get(edge.relation, "related")
        kinds.setdefault(other.id, kind)
        if edge.relation == RELATION_PARENT:
            depths[other.id] = -1
        elif edge.relation == RELATION_CHILD:
            depths[other.id] = 1
        else:
            depths.setdefault(other.id, 0)

    direct_ids = [node_id for node_id in nodes if node_id != focus.id]
    # Collect extended candidates per via-kind, then round-robin so parents/siblings
    # are not starved by child/acquaintance fan-out.
    via_order = ("parent", "sibling", "child", "related")
    pools: dict[str, list[KnowledgeNode]] = {kind: [] for kind in via_order}
    seen_extended: set[UUID] = set()
    seen_extended_nodes: list[KnowledgeNode] = []
    directs_sorted = sorted(
        direct_ids,
        key=lambda node_id: (
            via_order.index(kinds.get(node_id, "related"))
            if kinds.get(node_id, "related") in via_order
            else 9,
            nodes[node_id].name.lower(),
            str(node_id),
        ),
    )
    for direct_id in directs_sorted:
        via_kind = kinds.get(direct_id, "related")
        if via_kind not in pools:
            via_kind = "related"
        for edge in session.exec(select(KnowledgeEdge).where(KnowledgeEdge.from_id == direct_id)).all():
            if edge.to_id in nodes or edge.to_id in seen_extended:
                continue
            other = session.get(KnowledgeNode, edge.to_id)
            if other is None:
                continue
            if same_topic(other.name, focus.name):
                continue
            if any(same_topic(other.name, prior.name) for prior in nodes.values()):
                continue
            if any(same_topic(other.name, prior.name) for prior in seen_extended_nodes):
                continue
            seen_extended.add(other.id)
            seen_extended_nodes.append(other)
            pools[via_kind].append(other)

    extended: list[KnowledgeNode] = []
    while len(extended) < max_extended and any(pools.values()):
        for via_kind in via_order:
            bucket = pools[via_kind]
            if not bucket:
                continue
            extended.append(bucket.pop(0))
            if len(extended) >= max_extended:
                break

    for other in extended:
        nodes[other.id] = other
        kinds[other.id] = "extended"
        depths.setdefault(other.id, 0)

    ids = list(nodes.keys())
    edges = list(
        session.exec(
            select(KnowledgeEdge).where(col(KnowledgeEdge.from_id).in_(ids), col(KnowledgeEdge.to_id).in_(ids))
        ).all()
    ) if ids else []
    distances = _distances(focus.id, edges)
    # Direct first, then extended; stable within each band.
    kind_rank = {"focus": 0, "parent": 1, "sibling": 2, "child": 3, "related": 4, "extended": 5}

    def sort_key(node_id: UUID) -> tuple:
        return (
            kind_rank.get(kinds.get(node_id, "related"), 9),
            depths.get(node_id, 0),
            nodes[node_id].name.lower(),
            str(node_id),
        )

    node_payload = []
    for node_id in sorted(ids, key=sort_key):
        node = nodes[node_id]
        node_payload.append(
            {
                "id": str(node.id),
                "title": node.name,
                "description": node.description,
                "depth": depths.get(node_id, 0),
                "distance": distances.get(node_id, 0 if node_id == focus.id else 2 if kinds.get(node_id) == "extended" else 1),
                "kind": kinds.get(node_id, "related"),
            }
        )
    # Outbound from focus + links from directs into extended (for client context).
    edge_payload = [
        {"source": str(edge.from_id), "target": str(edge.to_id), "type": edge.relation}
        for edge in sorted(edges, key=lambda row: (str(row.from_id), row.relation, str(row.to_id)))
        if edge.from_id == focus.id
        or (edge.from_id in set(direct_ids) and kinds.get(edge.to_id) == "extended")
    ]
    incomplete = False
    if counts is not None:
        incomplete = not is_complete(session, focus.id, counts)
    return {
        "focus_node_id": str(focus.id),
        "incomplete": incomplete,
        "nodes": node_payload,
        "edges": edge_payload,
    }


def _distances(focus_id: UUID, edges: list[KnowledgeEdge]) -> dict[UUID, int]:
    adjacency: dict[UUID, set[UUID]] = {}
    for edge in edges:
        adjacency.setdefault(edge.from_id, set()).add(edge.to_id)
        adjacency.setdefault(edge.to_id, set()).add(edge.from_id)
    distances = {focus_id: 0}
    queue: deque[UUID] = deque([focus_id])
    while queue:
        current = queue.popleft()
        for neighbor in adjacency.get(current, ()):
            if neighbor in distances:
                continue
            distances[neighbor] = distances[current] + 1
            queue.append(neighbor)
    return distances
