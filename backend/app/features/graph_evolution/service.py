from __future__ import annotations

from uuid import UUID

from sqlmodel import Session, select

from app.core.errors import forbidden, graph_stale, invalid_graph, not_found
from app.core.time import utcnow
from app.features.accounts.models import User
from app.features.goals_trajectories.models import GoalGraph, LearningGoal
from app.features.goals_trajectories.service import replan
from app.features.graph_evolution.apply import apply_operations, objective_refs
from app.features.graph_evolution.models import (
    ConceptMapping,
    GraphChangeProposal,
    MigrationItem,
    MigrationRun,
    ObjectiveMapping,
)
from app.features.graph_evolution.policies import (
    EvidenceRef,
    ExplicitMap,
    ReviewRef,
    build_directives,
)
from app.features.knowledge_graph.models import Graph, GraphOverlay, GraphRelease
from app.features.knowledge_graph.service import get_graph, load_snapshot, publish_snapshot
from app.features.mastery.models import LearnerObjectiveState, MasteryEvidence
from app.features.mastery.service import recompute_objective
from app.features.platform.audit import write_audit
from app.features.retention.models import ReviewItem
from app.features.retention.service import retire_item


def store_proposal(
    session: Session,
    *,
    graph_id: UUID,
    base_release_id: UUID,
    actor: User | None,
    actor_type: str,
    trigger_type: str,
    operations: list[dict],
    risk_class: str = "low",
    sources: list[dict] | None = None,
    objective_maps: list[dict] | None = None,
    concept_maps: list[dict] | None = None,
    idempotency_key: str | None = None,
) -> GraphChangeProposal:
    if idempotency_key and actor is not None:
        existing = session.exec(
            select(GraphChangeProposal).where(
                GraphChangeProposal.actor_user_id == actor.id,
                GraphChangeProposal.idempotency_key == idempotency_key,
            )
        ).first()
        if existing is not None:
            return existing
    base = load_snapshot(session, base_release_id)
    candidate, _temp = apply_operations(base, operations)
    from app.features.knowledge_graph.identity import bind_existing_identities

    candidate = bind_existing_identities(session, candidate)
    from app.features.knowledge_graph.domain import diff_snapshots

    diff = diff_snapshots(base, candidate)
    proposal = GraphChangeProposal(
        graph_id=graph_id,
        base_release_id=base_release_id,
        actor_type=actor_type,
        actor_user_id=actor.id if actor else None,
        trigger_type=trigger_type,
        operations={"items": operations},
        diff=diff,
        validation={"ok": True, "sources": sources or []},
        status="validated",
        risk_class=risk_class,
        idempotency_key=idempotency_key,
    )
    session.add(proposal)
    session.flush()
    _store_maps(session, proposal.id, objective_maps or [], concept_maps or [])
    return proposal


def preview(session: Session, user: User, graph_id: UUID, proposal_id: UUID, goal_id: UUID | None) -> dict:
    proposal = _require_proposal(session, proposal_id, graph_id)
    before = load_snapshot(session, proposal.base_release_id)
    after, _temp = apply_operations(before, proposal.operations.get("items") or [])
    from app.features.knowledge_graph.identity import bind_existing_identities

    after = bind_existing_identities(session, after)
    explicit = _explicit_maps(session, proposal.id)
    evidence = _evidence_refs(session, user.id)
    reviews = _review_refs(session, user.id)
    directives = build_directives(objective_refs(before), objective_refs(after), explicit, evidence, reviews)
    preserved = sum(1 for item in directives if item.policy in {"preserve", "remap"} and item.target_objective_id)
    new = sum(1 for item in directives if item.policy == "unknown")
    reassess = sum(1 for item in directives if item.policy == "reassess")
    retired = sum(1 for item in directives if item.policy == "archive" and item.source_objective_id)
    proposal.impact_summary = {
        "preserved_objectives": preserved,
        "new_objectives": new,
        "reassessment_objectives": reassess,
        "retired_review_items": retired,
    }
    session.add(proposal)
    session.flush()
    return {
        "proposal_id": str(proposal.id),
        "from_release_id": str(proposal.base_release_id),
        "candidate_to_release_version": None,
        "impact": proposal.impact_summary,
        "mappings": [
            {
                "source_objective_id": str(item.source_objective_id) if item.source_objective_id else None,
                "target_objective_id": str(item.target_objective_id) if item.target_objective_id else None,
                "policy": item.policy,
                "confidence": item.confidence,
            }
            for item in directives
        ],
        "warnings": [],
        "goal_id": str(goal_id) if goal_id else None,
    }


def accept_private(session: Session, user: User, graph_id: UUID, proposal_id: UUID, goal_id: UUID | None) -> dict:
    graph = get_graph(session, graph_id)
    if graph.visibility != "shared" and graph.owner_user_id != user.id:
        raise forbidden()
    proposal = _require_proposal(session, proposal_id, graph_id)
    if proposal.status == "accepted_private" and proposal.result_release_id:
        return {"release_id": str(proposal.result_release_id), "proposal_id": str(proposal.id), "status": proposal.status}
    known = _known_bases(session, user.id, graph)
    if proposal.base_release_id not in known:
        current = str(graph.active_release_id) if graph.active_release_id else ""
        raise graph_stale(current)
    overlay = _overlay_for(session, user, graph, proposal.base_release_id)
    before = load_snapshot(session, proposal.base_release_id if overlay.active_private_release_id is None else overlay.active_private_release_id)
    # Publish from the release the overlay currently points at when one exists.
    base_for_publish = overlay.active_private_release_id or proposal.base_release_id
    if overlay.active_private_release_id and proposal.base_release_id != overlay.active_private_release_id:
        raise graph_stale(str(overlay.active_private_release_id))
    source = load_snapshot(session, base_for_publish)
    candidate, _temp = apply_operations(source, proposal.operations.get("items") or [])
    release = publish_snapshot(
        session,
        graph_id=graph.id,
        base_release_id=base_for_publish,
        snapshot=candidate,
        actor_user_id=user.id,
        overlay_id=overlay.id,
        proposal_id=proposal.id,
    )
    proposal.status = "accepted_private"
    proposal.result_release_id = release.id
    session.add(proposal)
    session.flush()
    migration = run_learner_migration(
        session,
        user_id=user.id,
        from_release_id=proposal.base_release_id,
        to_release_id=release.id,
        proposal_id=proposal.id,
        goal_id=goal_id,
    )
    _ = before
    return {"release_id": str(release.id), "proposal_id": str(proposal.id), "migration_id": str(migration.id), "status": migration.status}


def publish_shared(session: Session, user: User, graph_id: UUID, proposal_id: UUID) -> GraphRelease:
    graph = get_graph(session, graph_id)
    if graph.owner_user_id != user.id and not user.is_admin:
        raise forbidden("Shared publish requires the owner or an admin")
    proposal = _require_proposal(session, proposal_id, graph_id)
    sources = (proposal.validation or {}).get("sources") or []
    if proposal.risk_class == "high" and not sources:
        raise invalid_graph("missing_source")
    base = load_snapshot(session, proposal.base_release_id)
    candidate, _temp = apply_operations(base, proposal.operations.get("items") or [])
    release = publish_snapshot(
        session,
        graph_id=graph.id,
        base_release_id=proposal.base_release_id,
        snapshot=candidate,
        actor_user_id=user.id,
        proposal_id=proposal.id,
    )
    proposal.status = "published"
    proposal.result_release_id = release.id
    session.add(proposal)
    session.flush()
    return release


def run_learner_migration(
    session: Session,
    *,
    user_id: UUID,
    from_release_id: UUID,
    to_release_id: UUID,
    proposal_id: UUID | None,
    goal_id: UUID | None,
) -> MigrationRun:
    existing = session.exec(
        select(MigrationRun).where(
            MigrationRun.user_id == user_id,
            MigrationRun.from_release_id == from_release_id,
            MigrationRun.to_release_id == to_release_id,
        )
    ).first()
    if existing is not None and existing.status == "succeeded":
        return existing
    before = load_snapshot(session, from_release_id)
    after = load_snapshot(session, to_release_id)
    explicit = _explicit_maps(session, proposal_id) if proposal_id else []
    if existing is None:
        directives = build_directives(
            objective_refs(before),
            objective_refs(after),
            explicit,
            _evidence_refs(session, user_id),
            _review_refs(session, user_id),
        )
        existing = MigrationRun(
            user_id=user_id,
            from_release_id=from_release_id,
            to_release_id=to_release_id,
            proposal_id=proposal_id,
            goal_id=goal_id,
            status="running",
        )
        session.add(existing)
        session.flush()
        for directive in directives:
            session.add(
                MigrationItem(
                    migration_run_id=existing.id,
                    source_objective_id=directive.source_objective_id,
                    target_objective_id=directive.target_objective_id,
                    policy=directive.policy,
                    transferred_evidence_ids={"ids": [str(item) for item in directive.transfer_evidence_ids]},
                    reason=directive.reason,
                    needs_reassessment=directive.needs_reassessment,
                )
            )
        session.commit()
    else:
        existing.status = "running"
        session.add(existing)
        session.commit()

    items = list(session.exec(select(MigrationItem).where(MigrationItem.migration_run_id == existing.id)).all())
    moved_reviews: set[UUID] = set()
    for item in items:
        if item.result == "done":
            continue
        _apply_item(session, user_id, item, after, moved_reviews)
        item.result = "done"
        session.add(item)
        session.commit()

    _activate_goals(session, user_id, from_release_id, to_release_id, goal_id)
    existing.status = "succeeded"
    existing.completed_at = utcnow()
    existing.summary = {"items": len(items)}
    write_audit(
        session,
        actor=str(user_id),
        action="mastery.migrate",
        entity_type="migration_run",
        entity_id=str(existing.id),
        after={"from": str(from_release_id), "to": str(to_release_id), "items": len(items)},
    )
    session.add(existing)
    session.commit()
    return existing


def _apply_item(session: Session, user_id: UUID, item: MigrationItem, after, moved_reviews: set[UUID]) -> None:
    target = _find_objective(after, item.target_objective_id) if item.target_objective_id else None
    if item.policy in {"preserve", "remap"} and item.source_objective_id == item.target_objective_id:
        return
    if item.policy in {"preserve", "remap"} and target is not None:
        _transfer(session, user_id, item, target)
        _move_review(session, user_id, item, target, moved_reviews)
        recompute_objective(
            session,
            user_id=user_id,
            objective_id=target[0].objective_id,
            concept_id=target[1].concept_id,
            active_revision_id=target[0].revision_id,
        )
        return
    if item.policy == "reassess" and target is not None:
        recompute_objective(
            session,
            user_id=user_id,
            objective_id=target[0].objective_id,
            concept_id=target[1].concept_id,
            active_revision_id=target[0].revision_id,
            forced_status="needs_reassessment",
        )
        return
    if item.policy == "archive" and item.source_objective_id is not None:
        state = session.get(LearnerObjectiveState, (user_id, item.source_objective_id))
        if state is not None:
            state.status = "archived"
            session.add(state)
        for review in session.exec(
            select(ReviewItem).where(ReviewItem.user_id == user_id, ReviewItem.objective_id == item.source_objective_id, ReviewItem.status == "active")
        ).all():
            retire_item(session, review)


def _transfer(session: Session, user_id: UUID, item: MigrationItem, target) -> None:
    objective, concept = target
    existing_rows = list(
        session.exec(
            select(MasteryEvidence).where(MasteryEvidence.user_id == user_id, MasteryEvidence.objective_id == objective.objective_id)
        ).all()
    )
    seen = {(row.attempt_id, row.dimension) for row in existing_rows if row.attempt_id is not None}
    origins = {row.migration_origin_id for row in existing_rows if row.migration_origin_id}
    for raw_id in (item.transferred_evidence_ids or {}).get("ids") or []:
        source = session.get(MasteryEvidence, UUID(str(raw_id)))
        if source is None or source.id in origins:
            continue
        if source.attempt_id is not None and (source.attempt_id, source.dimension) in seen:
            continue
        copy = MasteryEvidence(
            user_id=user_id,
            attempt_id=source.attempt_id,
            objective_id=objective.objective_id,
            objective_revision_id=objective.revision_id,
            concept_revision_id=concept.revision_id,
            dimension=source.dimension,
            likelihood_weight=source.likelihood_weight,
            observed_score=source.observed_score,
            grading_method=source.grading_method,
            uncertain=source.uncertain,
            migration_origin_id=source.id,
        )
        session.add(copy)
        session.flush()
        if source.attempt_id is not None:
            seen.add((source.attempt_id, source.dimension))
        origins.add(source.id)


def _move_review(session: Session, user_id: UUID, item: MigrationItem, target, moved_reviews: set[UUID]) -> None:
    if item.source_objective_id is None:
        return
    review = session.exec(
        select(ReviewItem).where(
            ReviewItem.user_id == user_id,
            ReviewItem.objective_id == item.source_objective_id,
            ReviewItem.status == "active",
        )
    ).first()
    if review is None or review.id in moved_reviews:
        return
    objective, concept = target
    review.objective_id = objective.objective_id
    review.concept_id = concept.concept_id
    review.objective_revision_id = objective.revision_id
    moved_reviews.add(review.id)
    session.add(review)
    session.flush()


def _activate_goals(session: Session, user_id: UUID, from_release_id: UUID, to_release_id: UUID, goal_id: UUID | None) -> None:
    query = select(GoalGraph, LearningGoal).where(GoalGraph.goal_id == LearningGoal.id, LearningGoal.user_id == user_id)
    if goal_id is not None:
        query = query.where(LearningGoal.id == goal_id)
    for link, goal in session.exec(query).all():
        if link.release_id not in {from_release_id, None, to_release_id}:
            continue
        link.release_id = to_release_id
        release = session.get(GraphRelease, to_release_id)
        if release is not None:
            link.overlay_id = release.overlay_id
        session.add(link)
        if goal.status == "active":
            replan(session, goal, "graph_migration")
    session.flush()


def _find_objective(snapshot, objective_id: UUID):
    for concept in snapshot.concepts:
        for objective in concept.objectives:
            if objective.objective_id == objective_id:
                return objective, concept
    return None


def _overlay_for(session: Session, user: User, graph: Graph, base_release_id: UUID) -> GraphOverlay:
    overlay = session.exec(
        select(GraphOverlay).where(GraphOverlay.owner_user_id == user.id, GraphOverlay.base_graph_id == graph.id, GraphOverlay.status == "active")
    ).first()
    if overlay is None:
        overlay = GraphOverlay(
            base_graph_id=graph.id,
            owner_user_id=user.id,
            base_release_id=base_release_id,
            status="active",
        )
        session.add(overlay)
        session.flush()
    return overlay


def _known_bases(session: Session, user_id: UUID, graph: Graph) -> set[UUID]:
    bases: set[UUID] = set()
    if graph.active_release_id:
        bases.add(graph.active_release_id)
    for link, _goal in session.exec(
        select(GoalGraph, LearningGoal).where(
            GoalGraph.goal_id == LearningGoal.id,
            LearningGoal.user_id == user_id,
            GoalGraph.graph_id == graph.id,
        )
    ).all():
        if link.release_id:
            bases.add(link.release_id)
    overlays = session.exec(
        select(GraphOverlay).where(GraphOverlay.owner_user_id == user_id, GraphOverlay.base_graph_id == graph.id)
    ).all()
    for overlay in overlays:
        if overlay.active_private_release_id:
            bases.add(overlay.active_private_release_id)
        bases.add(overlay.base_release_id)
    return bases


def _require_proposal(session: Session, proposal_id: UUID, graph_id: UUID) -> GraphChangeProposal:
    proposal = session.get(GraphChangeProposal, proposal_id)
    if proposal is None or proposal.graph_id != graph_id:
        raise not_found("Proposal not found")
    return proposal


def _store_maps(session: Session, proposal_id: UUID, objective_maps: list[dict], concept_maps: list[dict]) -> None:
    for item in concept_maps:
        session.add(
            ConceptMapping(
                proposal_id=proposal_id,
                source_concept_id=_uuid(item.get("source_concept_id")),
                target_concept_id=_uuid(item.get("target_concept_id")),
                relation=item.get("relation") or "overlap",
                objective_mapping={"policy": item.get("policy")},
                confidence=float(item.get("confidence") or 1),
                validated_by=item.get("validated_by") or "rules",
            )
        )
    for item in objective_maps:
        session.add(
            ObjectiveMapping(
                proposal_id=proposal_id,
                source_objective_id=_uuid(item.get("source_objective_id")),
                target_objective_id=_uuid(item.get("target_objective_id")),
                policy=item["policy"],
                confidence=float(item.get("confidence") or 1),
            )
        )
    session.flush()


def _explicit_maps(session: Session, proposal_id: UUID | None) -> list[ExplicitMap]:
    if proposal_id is None:
        return []
    rows = session.exec(select(ObjectiveMapping).where(ObjectiveMapping.proposal_id == proposal_id)).all()
    return [
        ExplicitMap(row.source_objective_id, row.target_objective_id, row.policy, row.confidence)
        for row in rows
    ]


def _evidence_refs(session: Session, user_id: UUID) -> list[EvidenceRef]:
    rows = session.exec(select(MasteryEvidence).where(MasteryEvidence.user_id == user_id)).all()
    return [
        EvidenceRef(
            row.id,
            row.attempt_id,
            row.objective_id,
            row.dimension,
            row.observed_score,
            row.likelihood_weight,
            row.grading_method,
            row.objective_revision_id,
            row.concept_revision_id,
        )
        for row in rows
        if row.migration_origin_id is None
    ]


def _review_refs(session: Session, user_id: UUID) -> list[ReviewRef]:
    rows = session.exec(select(ReviewItem).where(ReviewItem.user_id == user_id)).all()
    return [
        ReviewRef(row.id, row.objective_id, row.fsrs_state, row.due_at.isoformat(), row.status) for row in rows
    ]


def _uuid(value) -> UUID | None:
    if not value:
        return None
    return value if isinstance(value, UUID) else UUID(str(value))
