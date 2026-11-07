from __future__ import annotations

from uuid import UUID

from sqlmodel import Session, select

from app.core.config import get_settings
from app.core.time import utcnow
from app.features.mastery.models import LearnerObjectiveState, MasteryEvidence
from app.features.mastery.project import DIMENSIONS, EvidenceView, project_objective, rollup_status


def evidence_views(rows: list[MasteryEvidence]) -> list[EvidenceView]:
    return [
        EvidenceView(
            observed_score=row.observed_score,
            likelihood_weight=row.likelihood_weight,
            grading_method=row.grading_method,
            dimension=row.dimension,
            uncertain=row.uncertain,
        )
        for row in rows
    ]


def recompute_objective(
    session: Session,
    *,
    user_id: UUID,
    objective_id: UUID,
    concept_id: UUID,
    active_revision_id: UUID,
    forced_status: str | None = None,
) -> LearnerObjectiveState:
    rows = list(
        session.exec(
            select(MasteryEvidence).where(
                MasteryEvidence.user_id == user_id,
                MasteryEvidence.objective_id == objective_id,
            )
        ).all()
    )
    projected = project_objective(evidence_views(rows), forced_status=forced_status)
    state = session.get(LearnerObjectiveState, (user_id, objective_id))
    if state is None:
        state = LearnerObjectiveState(
            user_id=user_id,
            objective_id=objective_id,
            concept_id=concept_id,
            active_revision_id=active_revision_id,
        )
        session.add(state)
    state.concept_id = concept_id
    state.active_revision_id = active_revision_id
    state.mastery_estimate = projected.estimate
    state.confidence = projected.confidence
    state.evidence_count = projected.evidence_count
    state.status = projected.status
    state.projection_version = get_settings().mastery_model_version
    state.dimensions = {
        name: {
            "estimate": item.estimate,
            "confidence": item.confidence,
            "status": item.status,
            "evidence_count": item.evidence_count,
        }
        for name, item in projected.dimensions.items()
    }
    if rows:
        state.last_assessed_at = utcnow()
    session.flush()
    return state


def add_evidence(
    session: Session,
    *,
    user_id: UUID,
    objective_id: UUID,
    objective_revision_id: UUID,
    concept_id: UUID,
    concept_revision_id: UUID,
    dimension: str,
    score: float,
    weight: float,
    method: str,
    attempt_id: UUID | None,
    uncertain: bool = False,
) -> MasteryEvidence:
    if dimension not in DIMENSIONS:
        dimension = "understanding"
    row = MasteryEvidence(
        user_id=user_id,
        attempt_id=attempt_id,
        objective_id=objective_id,
        objective_revision_id=objective_revision_id,
        concept_revision_id=concept_revision_id,
        dimension=dimension,
        likelihood_weight=weight,
        observed_score=score,
        grading_method=method,
        uncertain=uncertain,
    )
    session.add(row)
    session.flush()
    recompute_objective(
        session,
        user_id=user_id,
        objective_id=objective_id,
        concept_id=concept_id,
        active_revision_id=objective_revision_id,
    )
    return row


def concept_rollup(session: Session, user_id: UUID, concept_id: UUID, objective_ids: list[UUID]) -> dict:
    states = []
    for objective_id in objective_ids:
        state = session.get(LearnerObjectiveState, (user_id, objective_id))
        if state is not None:
            states.append(state)
    if not states:
        return {"status": "unknown", "estimate": 0.0, "confidence": 0.0, "evidence_count": 0}
    return {
        "status": rollup_status([item.status for item in states]),
        "estimate": round(sum(item.mastery_estimate for item in states) / len(states), 4),
        "confidence": round(sum(item.confidence for item in states) / len(states), 4),
        "evidence_count": sum(item.evidence_count for item in states),
    }
