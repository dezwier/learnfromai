"""Deterministic trajectory planner. No model calls."""

from __future__ import annotations

from dataclasses import dataclass
from uuid import UUID

PLANNER_VERSION = "deterministic-v1"


@dataclass(frozen=True)
class PlanCandidate:
    objective_id: UUID
    concept_id: UUID
    title: str
    prereq_objective_ids: tuple[UUID, ...]
    status: str
    mastery: float
    confidence: float
    estimated_minutes: int
    goal_relevance: float
    has_due_review: bool
    step_type: str


@dataclass(frozen=True)
class PlannedStep:
    objective_id: UUID
    concept_id: UUID
    step_type: str
    rank: int
    rationale: str
    estimated_minutes: int
    score: float


def plan_trajectory(
    candidates: list[PlanCandidate],
    *,
    review_slots: int = 2,
    learn_slots: int = 4,
) -> list[PlannedStep]:
    status_by_objective = {item.objective_id: item.status for item in candidates}
    scored: list[tuple[float, PlanCandidate]] = []
    for candidate in candidates:
        if candidate.status == "archived":
            continue
        if candidate.status == "demonstrated" and not candidate.has_due_review:
            continue
        prereqs_met = all(status_by_objective.get(prereq) == "demonstrated" for prereq in candidate.prereq_objective_ids)
        if candidate.step_type != "review" and not candidate.has_due_review and not prereqs_met:
            continue
        score = _score(candidate)
        scored.append((score, candidate))

    def sort_key(item: tuple[float, PlanCandidate]) -> tuple:
        score, candidate = item
        return (-score, str(candidate.objective_id))

    due = sorted((item for item in scored if item[1].has_due_review), key=sort_key)
    learn = sorted((item for item in scored if not item[1].has_due_review), key=sort_key)
    chosen = due[:review_slots] + learn[:learn_slots]
    steps: list[PlannedStep] = []
    for rank, (score, candidate) in enumerate(chosen, start=1):
        step_type = "review" if candidate.has_due_review else "learn"
        steps.append(
            PlannedStep(
                objective_id=candidate.objective_id,
                concept_id=candidate.concept_id,
                step_type=step_type,
                rank=rank,
                rationale=_rationale(candidate, score),
                estimated_minutes=candidate.estimated_minutes,
                score=round(score, 6),
            )
        )
    return steps


def steps_signature(steps: list[PlannedStep]) -> tuple:
    return tuple((step.concept_id, step.objective_id, step.step_type, step.rank) for step in steps)


def _score(candidate: PlanCandidate) -> float:
    if candidate.status == "unknown":
        readiness, gain, uncertainty = 1.0, 1.0, 1.0
    elif candidate.status == "needs_reassessment":
        readiness, gain, uncertainty = 1.0, 0.8, 0.7
    elif candidate.has_due_review:
        readiness, gain, uncertainty = 1.0, 0.55, 0.4
    else:
        readiness = 0.7
        gain = max(0.15, 1.0 - candidate.mastery)
        uncertainty = max(0.0, 1.0 - candidate.confidence)
    minutes = max(candidate.estimated_minutes, 1)
    return candidate.goal_relevance * readiness * gain * (1.0 + uncertainty) / minutes


def _rationale(candidate: PlanCandidate, score: float) -> str:
    gate = "due review" if candidate.has_due_review else candidate.status
    return (
        f"priority={score:.4f}; relevance={candidate.goal_relevance:.2f}; "
        f"status={gate}; mastery={candidate.mastery:.2f}; confidence={candidate.confidence:.2f}"
    )
