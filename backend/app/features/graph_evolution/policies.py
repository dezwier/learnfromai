"""Objective mapping and evidence migration. Historical rows are never inputs to UPDATE."""

from __future__ import annotations

from dataclasses import dataclass, field
from uuid import UUID

POLICIES = frozenset({"preserve", "reassess", "unknown", "archive", "remap"})


@dataclass(frozen=True)
class ObjectiveRef:
    objective_id: UUID
    concept_id: UUID
    fingerprint: str
    statement: str


@dataclass(frozen=True)
class ExplicitMap:
    source_objective_id: UUID | None
    target_objective_id: UUID | None
    policy: str
    confidence: float = 1.0


@dataclass(frozen=True)
class EvidenceRef:
    evidence_id: UUID
    attempt_id: UUID | None
    objective_id: UUID
    dimension: str
    observed_score: float
    likelihood_weight: float
    grading_method: str
    objective_revision_id: UUID
    concept_revision_id: UUID


@dataclass(frozen=True)
class ReviewRef:
    review_item_id: UUID
    objective_id: UUID
    fsrs_state: dict
    due_at_iso: str
    status: str


@dataclass
class MigrationDirective:
    source_objective_id: UUID | None
    target_objective_id: UUID | None
    policy: str
    reason: str
    confidence: float = 1.0
    transfer_evidence_ids: list[UUID] = field(default_factory=list)
    needs_reassessment: bool = False
    keep_fsrs_item_id: UUID | None = None


def build_directives(
    before: list[ObjectiveRef],
    after: list[ObjectiveRef],
    explicit: list[ExplicitMap],
    evidence: list[EvidenceRef],
    reviews: list[ReviewRef],
) -> list[MigrationDirective]:
    before_ids = {item.objective_id: item for item in before}
    after_ids = {item.objective_id: item for item in after}
    explicit_by_source: dict[UUID | None, list[ExplicitMap]] = {}
    for item in explicit:
        if item.policy not in POLICIES:
            raise ValueError(f"unknown policy {item.policy}")
        explicit_by_source.setdefault(item.source_objective_id, []).append(item)

    directives: list[MigrationDirective] = []
    consumed_targets: set[UUID] = set()

    for source_id, source in before_ids.items():
        maps = explicit_by_source.get(source_id, [])
        if maps:
            for item in maps:
                target = after_ids.get(item.target_objective_id) if item.target_objective_id else None
                policy = item.policy
                if policy in {"preserve", "remap"} and target is None:
                    policy = "archive"
                directive = _directive_for(policy, source, target, evidence, reviews, item.confidence, "explicit")
                directives.append(directive)
                if target is not None:
                    consumed_targets.add(target.objective_id)
            continue
        target = after_ids.get(source_id)
        if target is None:
            directives.append(
                MigrationDirective(source_id, None, "archive", "removed_from_release", needs_reassessment=False)
            )
            continue
        if target.fingerprint == source.fingerprint:
            directives.append(_directive_for("preserve", source, target, evidence, reviews, 1.0, "identity"))
            consumed_targets.add(target.objective_id)
        else:
            directives.append(
                _directive_for("reassess", source, target, evidence, reviews, 1.0, "semantic_fingerprint_changed")
            )
            consumed_targets.add(target.objective_id)

    for target_id, target in after_ids.items():
        if target_id in consumed_targets:
            continue
        if target_id in before_ids:
            continue
        directives.append(MigrationDirective(None, target_id, "unknown", "new_objective"))
    return directives


def _directive_for(
    policy: str,
    source: ObjectiveRef,
    target: ObjectiveRef | None,
    evidence: list[EvidenceRef],
    reviews: list[ReviewRef],
    confidence: float,
    reason: str,
) -> MigrationDirective:
    source_evidence = [item for item in evidence if item.objective_id == source.objective_id]
    review = next((item for item in reviews if item.objective_id == source.objective_id and item.status == "active"), None)
    if policy in {"preserve", "remap"} and target is not None:
        deduped = _dedupe_evidence(source_evidence)
        return MigrationDirective(
            source.objective_id,
            target.objective_id,
            policy,
            reason,
            confidence,
            transfer_evidence_ids=[item.evidence_id for item in deduped],
            keep_fsrs_item_id=review.review_item_id if review else None,
        )
    if policy == "reassess" and target is not None:
        return MigrationDirective(
            source.objective_id,
            target.objective_id,
            "reassess",
            reason,
            confidence,
            needs_reassessment=True,
        )
    if policy == "unknown":
        return MigrationDirective(source.objective_id, target.objective_id if target else None, "unknown", reason, confidence)
    return MigrationDirective(source.objective_id, None, "archive", reason, confidence)


def _dedupe_evidence(rows: list[EvidenceRef]) -> list[EvidenceRef]:
    seen_attempt: set[tuple[UUID | None, str]] = set()
    seen_id: set[UUID] = set()
    kept: list[EvidenceRef] = []
    for row in rows:
        if row.evidence_id in seen_id:
            continue
        key = (row.attempt_id, row.dimension)
        if row.attempt_id is not None and key in seen_attempt:
            continue
        seen_id.add(row.evidence_id)
        if row.attempt_id is not None:
            seen_attempt.add(key)
        kept.append(row)
    return kept


def merge_evidence(groups: list[list[EvidenceRef]]) -> list[EvidenceRef]:
    """Union evidence onto one target. Same evidence id or same attempt+dimension counts once."""
    return _dedupe_evidence([row for group in groups for row in group])
