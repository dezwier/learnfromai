from __future__ import annotations

from datetime import datetime
from uuid import UUID, uuid4

from sqlalchemy import Column, DateTime, Index, text
from sqlalchemy.dialects.postgresql import JSONB
from sqlmodel import Field, SQLModel

from app.core.time import utcnow


class GraphChangeProposal(SQLModel, table=True):
    __tablename__ = "graph_change_proposals"
    __table_args__ = (
        Index(
            "uq_proposal_idempotency",
            "actor_user_id",
            "idempotency_key",
            unique=True,
            postgresql_where=text("idempotency_key IS NOT NULL"),
        ),
    )

    id: UUID = Field(default_factory=uuid4, primary_key=True)
    graph_id: UUID = Field(foreign_key="graphs.id", index=True)
    base_release_id: UUID = Field(foreign_key="graph_releases.id")
    actor_type: str
    actor_user_id: UUID | None = Field(default=None, foreign_key="users.id")
    trigger_type: str
    operations: dict = Field(default_factory=dict, sa_column=Column(JSONB, nullable=False))
    diff: dict = Field(default_factory=dict, sa_column=Column(JSONB, nullable=False))
    validation: dict = Field(default_factory=dict, sa_column=Column(JSONB, nullable=False))
    status: str = "proposed"
    impact_summary: dict = Field(default_factory=dict, sa_column=Column(JSONB, nullable=False))
    risk_class: str = "low"
    idempotency_key: str | None = None
    result_release_id: UUID | None = Field(default=None, foreign_key="graph_releases.id")
    created_at: datetime = Field(default_factory=utcnow, sa_column=Column(DateTime(timezone=True), nullable=False))


class ConceptMapping(SQLModel, table=True):
    __tablename__ = "concept_mappings"

    id: UUID = Field(default_factory=uuid4, primary_key=True)
    proposal_id: UUID = Field(foreign_key="graph_change_proposals.id", index=True)
    source_concept_id: UUID | None = Field(default=None, foreign_key="concepts.id")
    target_concept_id: UUID | None = None
    relation: str
    objective_mapping: dict = Field(default_factory=dict, sa_column=Column(JSONB, nullable=False))
    confidence: float = 1.0
    validated_by: str = "rules"


class ObjectiveMapping(SQLModel, table=True):
    """Objective ids live in rows. A concept-level label is not enough to move mastery.

    Target ids may be created when the proposal is published, so the target column
    is not a foreign key until that objective row exists.
    """

    __tablename__ = "objective_mappings"

    id: UUID = Field(default_factory=uuid4, primary_key=True)
    proposal_id: UUID = Field(foreign_key="graph_change_proposals.id", index=True)
    source_objective_id: UUID | None = Field(default=None, foreign_key="learning_objectives.id")
    target_objective_id: UUID | None = None
    policy: str
    confidence: float = 1.0


class MigrationRun(SQLModel, table=True):
    __tablename__ = "migration_runs"
    __table_args__ = (
        Index("ix_migration_runs_user_status", "user_id", "status"),
        Index(
            "uq_migration_user_releases",
            "user_id",
            "from_release_id",
            "to_release_id",
            unique=True,
        ),
    )

    id: UUID = Field(default_factory=uuid4, primary_key=True)
    user_id: UUID = Field(foreign_key="users.id", index=True)
    from_release_id: UUID = Field(foreign_key="graph_releases.id")
    to_release_id: UUID = Field(foreign_key="graph_releases.id")
    proposal_id: UUID | None = Field(default=None, foreign_key="graph_change_proposals.id")
    goal_id: UUID | None = Field(default=None, foreign_key="learning_goals.id")
    status: str = "queued"
    summary: dict = Field(default_factory=dict, sa_column=Column(JSONB, nullable=False))
    created_at: datetime = Field(default_factory=utcnow, sa_column=Column(DateTime(timezone=True), nullable=False))
    completed_at: datetime | None = Field(default=None, sa_column=Column(DateTime(timezone=True), nullable=True))


class MigrationItem(SQLModel, table=True):
    __tablename__ = "migration_items"

    id: UUID = Field(default_factory=uuid4, primary_key=True)
    migration_run_id: UUID = Field(foreign_key="migration_runs.id", index=True)
    source_objective_id: UUID | None = Field(default=None, foreign_key="learning_objectives.id")
    target_objective_id: UUID | None = Field(default=None, foreign_key="learning_objectives.id")
    policy: str
    transferred_evidence_ids: dict = Field(default_factory=dict, sa_column=Column(JSONB, nullable=False))
    result: str | None = None
    reason: str = ""
    needs_reassessment: bool = False
