"""Explainable per-objective mastery projection. Evidence in, state out."""

from __future__ import annotations

from dataclasses import dataclass

WEAK_METHODS = frozenset({"self_report", "reading"})
METHOD_WEIGHT_CAP = {
    "self_report": 0.15,
    "reading": 0.15,
    "mcq": 0.55,
    "exact": 1.0,
    "keyword": 1.0,
    "model": 0.85,
    "numeric": 1.0,
}
DIMENSIONS = ("recall", "understanding", "application")
PRIOR_K = 4.0


@dataclass(frozen=True)
class EvidenceView:
    observed_score: float
    likelihood_weight: float
    grading_method: str
    dimension: str
    uncertain: bool = False


@dataclass(frozen=True)
class DimensionProjection:
    estimate: float
    confidence: float
    status: str
    evidence_count: int


@dataclass(frozen=True)
class ObjectiveProjection:
    estimate: float
    confidence: float
    status: str
    evidence_count: int
    dimensions: dict[str, DimensionProjection]


def project_objective(evidence: list[EvidenceView], *, forced_status: str | None = None) -> ObjectiveProjection:
    dimensions = {
        name: _dimension([item for item in evidence if item.dimension == name]) for name in DIMENSIONS
    }
    estimate, confidence, status, count = _stats(evidence)
    if forced_status in {"needs_reassessment", "archived"}:
        status = forced_status
    return ObjectiveProjection(estimate, confidence, status, count, dimensions)


def _dimension(evidence: list[EvidenceView]) -> DimensionProjection:
    estimate, confidence, status, count = _stats(evidence)
    return DimensionProjection(estimate, confidence, status, count)


def _stats(evidence: list[EvidenceView]) -> tuple[float, float, str, int]:
    if not evidence:
        return 0.0, 0.0, "unknown", 0
    weighted = [_capped(item) for item in evidence]
    weight_sum = sum(weight for weight, _score in weighted)
    if weight_sum <= 0:
        return 0.0, 0.0, "unknown", len(evidence)
    estimate = sum(weight * score for weight, score in weighted) / weight_sum
    confidence = weight_sum / (weight_sum + PRIOR_K)
    only_weak = all(item.grading_method in WEAK_METHODS for item in evidence)
    uncertain = any(item.uncertain for item in evidence)
    if only_weak or confidence < 0.2:
        status = "learning" if estimate > 0 else "unknown"
    elif estimate >= 0.75 and confidence >= 0.5 and not uncertain:
        status = "demonstrated"
    else:
        status = "learning"
    return round(estimate, 4), round(confidence, 4), status, len(evidence)


def _capped(item: EvidenceView) -> tuple[float, float]:
    cap = METHOD_WEIGHT_CAP.get(item.grading_method, 1.0)
    return min(item.likelihood_weight, cap), max(0.0, min(1.0, item.observed_score))


def rollup_status(statuses: list[str]) -> str:
    if not statuses:
        return "unknown"
    order = ["needs_reassessment", "learning", "unknown", "archived", "demonstrated"]
    for status in order:
        if status in statuses:
            return status
    return statuses[0]
