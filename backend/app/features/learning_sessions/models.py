from __future__ import annotations

from datetime import datetime
from uuid import UUID, uuid4

from sqlalchemy import Column, DateTime, Index, text
from sqlalchemy.dialects.postgresql import JSONB
from sqlmodel import Field, SQLModel

from app.core.time import utcnow


class LearningSession(SQLModel, table=True):
    __tablename__ = "learning_sessions"

    id: UUID = Field(default_factory=uuid4, primary_key=True)
    user_id: UUID = Field(foreign_key="users.id", index=True)
    goal_id: UUID = Field(foreign_key="learning_goals.id", index=True)
    trajectory_id: UUID = Field(foreign_key="trajectories.id")
    release_id: UUID = Field(foreign_key="graph_releases.id")
    started_at: datetime = Field(default_factory=utcnow, sa_column=Column(DateTime(timezone=True), nullable=False))
    ended_at: datetime | None = Field(default=None, sa_column=Column(DateTime(timezone=True), nullable=True))
    status: str = "active"
    cursor_rank: int = 1
    activity_phase: str = "explain"


class AssessmentAttempt(SQLModel, table=True):
    __tablename__ = "assessment_attempts"
    __table_args__ = (
        Index(
            "uq_attempt_idempotency",
            "user_id",
            "idempotency_key",
            unique=True,
            postgresql_where=text("idempotency_key IS NOT NULL"),
        ),
    )

    id: UUID = Field(default_factory=uuid4, primary_key=True)
    user_id: UUID = Field(foreign_key="users.id", index=True)
    session_id: UUID | None = Field(default=None, foreign_key="learning_sessions.id", index=True)
    activity_id: UUID = Field(foreign_key="learning_activities.id")
    concept_revision_id: UUID = Field(foreign_key="concept_revisions.id")
    response: dict = Field(default_factory=dict, sa_column=Column(JSONB, nullable=False))
    score: float | None = None
    rubric_results: dict = Field(default_factory=dict, sa_column=Column(JSONB, nullable=False))
    confidence: float | None = None
    grading_method: str = "pending"
    grader_version: str = ""
    idempotency_key: str | None = None
    created_at: datetime = Field(default_factory=utcnow, sa_column=Column(DateTime(timezone=True), nullable=False))
