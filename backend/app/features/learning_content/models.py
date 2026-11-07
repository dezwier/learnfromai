from __future__ import annotations

from datetime import datetime
from uuid import UUID, uuid4

from sqlalchemy import Column, DateTime
from sqlalchemy.dialects.postgresql import JSONB
from sqlmodel import Field, SQLModel

from app.core.time import utcnow


class LearningActivity(SQLModel, table=True):
    __tablename__ = "learning_activities"

    id: UUID = Field(default_factory=uuid4, primary_key=True)
    concept_revision_id: UUID = Field(foreign_key="concept_revisions.id", index=True)
    kind: str
    body: dict = Field(default_factory=dict, sa_column=Column(JSONB, nullable=False))
    rubric: dict = Field(default_factory=dict, sa_column=Column(JSONB, nullable=False))
    content_hash: str = Field(index=True)
    prompt_version: str
    model: str
    review_status: str = "generated"
    language: str = "en"
    difficulty: int = 1
    created_at: datetime = Field(default_factory=utcnow, sa_column=Column(DateTime(timezone=True), nullable=False))


class ActivityObjective(SQLModel, table=True):
    """Relational objective pins. JSON inside the activity body is not the source of truth."""

    __tablename__ = "activity_objectives"

    activity_id: UUID = Field(foreign_key="learning_activities.id", primary_key=True)
    objective_id: UUID = Field(foreign_key="learning_objectives.id", primary_key=True)
    objective_revision_id: UUID = Field(foreign_key="objective_revisions.id")
