from __future__ import annotations

from datetime import datetime
from uuid import UUID, uuid4

from sqlalchemy import Column, DateTime, Index, text
from sqlalchemy.dialects.postgresql import JSONB
from sqlmodel import Field, SQLModel

from app.core.time import utcnow


class MasteryEvidence(SQLModel, table=True):
    __tablename__ = "mastery_evidence"
    __table_args__ = (
        Index(
            "uq_evidence_migration_origin",
            "user_id",
            "objective_id",
            "migration_origin_id",
            unique=True,
            postgresql_where=text("migration_origin_id IS NOT NULL"),
        ),
    )

    id: UUID = Field(default_factory=uuid4, primary_key=True)
    user_id: UUID = Field(foreign_key="users.id", index=True)
    attempt_id: UUID | None = Field(default=None, foreign_key="assessment_attempts.id")
    objective_id: UUID = Field(foreign_key="learning_objectives.id", index=True)
    objective_revision_id: UUID = Field(foreign_key="objective_revisions.id")
    concept_revision_id: UUID = Field(foreign_key="concept_revisions.id")
    dimension: str
    likelihood_weight: float
    observed_score: float
    grading_method: str = "exact"
    uncertain: bool = False
    migration_origin_id: UUID | None = Field(default=None, foreign_key="mastery_evidence.id")
    created_at: datetime = Field(default_factory=utcnow, sa_column=Column(DateTime(timezone=True), nullable=False))


class LearnerObjectiveState(SQLModel, table=True):
    __tablename__ = "learner_objective_states"

    user_id: UUID = Field(foreign_key="users.id", primary_key=True)
    objective_id: UUID = Field(foreign_key="learning_objectives.id", primary_key=True)
    concept_id: UUID = Field(foreign_key="concepts.id", index=True)
    active_revision_id: UUID = Field(foreign_key="objective_revisions.id")
    mastery_estimate: float = 0.0
    confidence: float = 0.0
    evidence_count: int = 0
    last_assessed_at: datetime | None = Field(default=None, sa_column=Column(DateTime(timezone=True), nullable=True))
    status: str = "unknown"
    projection_version: str = "weighted-mean-v1"
    dimensions: dict = Field(default_factory=dict, sa_column=Column(JSONB, nullable=False))
