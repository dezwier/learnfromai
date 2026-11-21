"""Worker entry: expand a focus neighborhood via LLM + merge."""

from __future__ import annotations

from uuid import UUID

from sqlmodel import Session, select

from app.features.knowledge_graph.identity import canonical_key_for
from app.features.knowledge_graph.neighborhood.constants import (
    BUCKET_RELATION,
    is_complete,
    relation_counts,
    set_progress,
)
from app.features.knowledge_graph.neighborhood.dedupe import consolidate_near_duplicates, _merge_node_into
from app.features.knowledge_graph.neighborhood.resolve_link import (
    _bucket_items,
    _link_resolved_batch,
    _match_topics_batch,
    _pack_existing,
    _resolve_local,
    ensure_focus_node,
)
from app.features.knowledge_graph.neighborhood.subgraph import build_subgraph
from app.features.knowledge_graph.node_models import (
    KnowledgeEdge,
    KnowledgeNode,
    KnowledgeRequest,
    KnowledgeRequestNode,
)
from app.features.platform.jobs import renew_lease
from app.features.platform.llm import assert_user_quota, bind_usage_sink, maybe_record_usage
from app.features.platform.models import GenerationJob
from app.features.platform.neighborhood_llm import BUCKETS, parse_uuid


def expand_neighborhood(session: Session, job: GenerationJob) -> dict:
    """Scenarios: existing focus → under-budget; new topic → retrieve+sameness → under-budget or neighbor."""
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
    from app.features.accounts.models import User
    from app.features.knowledge_graph.preferences import min_per_bucket, preferred_llm_provider

    total = int(payload.get("total") or 16)
    if total <= 0:
        # Legacy jobs stored per-bucket targets.
        total = sum(int(payload.get(bucket) or 0) for bucket in BUCKETS) or 16
    counts = {
        "total": total,
        "min_per_bucket": int(payload.get("min_per_bucket") or min_per_bucket(total)),
        "extended": int(payload.get("extended") or 16),
    }
    focus_id = parse_uuid(payload.get("focus_id"))
    topic = str(payload.get("topic") or "").strip() or None
    from_existing_focus = bool(payload.get("from_existing_focus"))
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

    user = session.get(User, user_id)
    from app.features.knowledge_graph import neighborhood as _neighborhood
    llm = _neighborhood.get_neighborhood_llm(preferred_llm_provider(user))
    # Keep the lease alive across provider attempt timeouts (each can take ~60s).
    setattr(llm, "heartbeat", lambda: renew_lease(session, job))
    bind_usage_sink(llm, session, user_id=user_id, job_id=job.id, task="neighborhood")

    # Consolidate may have deleted focus_id; fall back to topic lookup for the keeper.
    focus = session.get(KnowledgeNode, focus_id) if focus_id is not None else None
    if focus is None:
        focus = ensure_focus_node(session, topic=topic, node_id=None)
        from_existing_focus = False

    if from_existing_focus:
        # Scenarios 3 / 5: known tile — skip focus retrieve/sameness.
        pass
    else:
        # Scenarios 1 / 2 / 4: new topic — retrieve (+ sameness if ambiguous).
        set_progress(session, job, stage="resolve", message="Matching topic against the graph…", fraction=0.08)
        focus = _resolve_focus_topic(
            session,
            llm=llm,
            user_id=user_id,
            job_id=job.id,
            topic=topic or focus.name,
            provisional=focus,
        )
        session.commit()

    if focus_id is not None and focus.id != focus_id:
        job.payload = {**(job.payload or {}), "focus_id": str(focus.id)}
        session.add(job)
    session.commit()

    # Under-budget check (scenarios 4 / 5 complete → Done).
    have_before = relation_counts(session, focus.id)
    neighbors_before = sum(have_before.get(bucket, 0) for bucket in BUCKET_RELATION)

    if is_complete(session, focus.id, counts):
        set_progress(session, job, stage="done", message="Neighborhood already complete", fraction=1.0)
        request = _persist_request(session, user_id=user_id, focus=focus, counts=counts, job_id=job.id)
        session.commit()
        return {
            "focus_id": str(focus.id),
            "request_id": str(request.id),
            "skipped": True,
            "neighbors_before": neighbors_before,
            "neighbors_added": 0,
            "neighbor_count": neighbors_before,
        }

    have = have_before
    existing_total = neighbors_before
    need = max(0, total - existing_total)
    exclude_titles = _direct_neighbor_titles(session, focus.id)
    prefer_buckets = [
        bucket
        for bucket in BUCKETS
        if have.get(bucket, 0) < int(counts.get("min_per_bucket") or 0)
    ]
    gen_counts = {
        "total": need,
        "min_per_bucket": int(counts.get("min_per_bucket") or 2),
        "extended": int(counts.get("extended") or 16),
        "exclude_titles": exclude_titles,
    }
    if exclude_titles and prefer_buckets:
        gen_counts["prefer_buckets"] = prefer_buckets

    set_progress(session, job, stage="generate", message="Asking the model for related topics…", fraction=0.15)
    assert_user_quota(session, user_id)
    neighborhood, usage = llm.generate_neighborhood(focus.name if not topic else topic, gen_counts)
    renew_lease(session, job)
    maybe_record_usage(
        session, llm, user_id=user_id, job_id=job.id, task="neighborhood", usage=usage
    )
    session.commit()
    assert_user_quota(session, user_id)

    focus_spec = neighborhood.get("focus") if isinstance(neighborhood.get("focus"), dict) else {}
    if focus_spec.get("description") and not focus.description:
        focus.description = str(focus_spec.get("description") or "").strip() or focus.description
        session.add(focus)
        session.commit()

    set_progress(session, job, stage="merge", message="Merging topics into the shared graph…", fraction=0.35)
    linked: dict[str, list[UUID]] = {bucket: [] for bucket in BUCKETS}
    seen_names: set[str] = {canonical_key_for(focus.name)}
    seen_titles: list[str] = [focus.name, *exclude_titles]
    for title in exclude_titles:
        seen_names.add(canonical_key_for(title))
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
        progress_span=0.55,
    )

    set_progress(session, job, stage="persist", message="Saving neighborhood…", fraction=0.95)
    request = _persist_request(session, user_id=user_id, focus=focus, counts=counts, job_id=job.id)
    set_progress(session, job, stage="done", message="Neighborhood ready", fraction=1.0)
    session.commit()
    neighbors_added = sum(len(ids) for ids in linked.values())
    have_after = relation_counts(session, focus.id)
    neighbors_after = sum(have_after.get(bucket, 0) for bucket in BUCKET_RELATION)
    return {
        "focus_id": str(focus.id),
        "request_id": str(request.id),
        "skipped": False,
        "neighbors_before": neighbors_before,
        "neighbors_added": neighbors_added,
        "neighbor_count": neighbors_after,
    }


def _direct_neighbor_titles(session: Session, focus_id: UUID) -> list[str]:
    titles: list[str] = []
    seen: set[str] = set()
    for edge in session.exec(select(KnowledgeEdge).where(KnowledgeEdge.from_id == focus_id)).all():
        other = session.get(KnowledgeNode, edge.to_id)
        if other is None:
            continue
        key = canonical_key_for(other.name)
        if key in seen:
            continue
        seen.add(key)
        titles.append(other.name)
    return titles


def _resolve_focus_topic(
    session: Session,
    *,
    llm,
    user_id: UUID,
    job_id: UUID | None,
    topic: str,
    provisional: KnowledgeNode,
) -> KnowledgeNode:
    """Retrieve (+ sameness if needed) for a new topic; reuse existing tile or keep provisional."""
    name = topic.strip() or provisional.name
    node, near = _resolve_local(session, name=name, description=provisional.description)
    if node is None and near:
        matches = _match_topics_batch(
            session,
            llm=llm,
            user_id=user_id,
            job_id=job_id,
            pending=[
                {
                    "key": "focus",
                    "name": name,
                    "description": provisional.description,
                    "existing": _pack_existing(near),
                }
            ],
        )
        chosen_id = matches.get("focus")
        if chosen_id is not None:
            node = session.get(KnowledgeNode, chosen_id)
    if node is None:
        return provisional
    if node.id == provisional.id:
        return provisional
    # Reuse an existing tile; fold the provisional focus into it when distinct.
    _merge_node_into(session, keep=node, drop=provisional)
    return node


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
        max_extended=int(counts.get("extended") or 16),
        counts=counts,
    )
    # Audit columns: parents holds the total budget; siblings holds min-per-bucket.
    request = KnowledgeRequest(
        user_id=user_id,
        focus_id=focus.id,
        parents=int(counts.get("total") or 16),
        siblings=int(counts.get("min_per_bucket") or 2),
        children=0,
        acquaintances=0,
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


