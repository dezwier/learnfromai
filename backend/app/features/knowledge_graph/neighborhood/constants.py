"""Shared neighborhood relation constants and progress helpers."""

from __future__ import annotations

from uuid import UUID

from sqlmodel import Session, select

from app.features.knowledge_graph.node_models import KnowledgeEdge
from app.features.platform.jobs import renew_lease
from app.features.platform.models import GenerationJob

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
    """Complete when direct neighbors meet the user's total budget."""
    have = relation_counts(session, focus_id)
    total = int(counts.get("total") or sum(int(counts.get(b, 0)) for b in BUCKET_RELATION))
    return sum(have.get(bucket, 0) for bucket in BUCKET_RELATION) >= total


def set_progress(session: Session, job: GenerationJob, *, stage: str, message: str, fraction: float) -> None:
    job.progress = {"stage": stage, "message": message, "fraction": max(0.0, min(1.0, fraction))}
    # Renew while reporting progress so a second worker cannot restart the same job mid-flight.
    renew_lease(session, job)


