from __future__ import annotations

from datetime import datetime
from uuid import UUID, uuid4

from sqlalchemy import Column, DateTime, Index
from sqlalchemy.dialects.postgresql import JSONB
from sqlmodel import Field, SQLModel

from app.core.time import utcnow


class ReviewItem(SQLModel, table=True):
    __tablename__ = "review_items"
    __table_args__ = (Index("ix_review_items_due", "user_id", "status", "due_at"),)

    id: UUID = Field(default_factory=uuid4, primary_key=True)
    user_id: UUID = Field(foreign_key="users.id", index=True)
    concept_id: UUID = Field(foreign_key="concepts.id")
    objective_id: UUID = Field(foreign_key="learning_objectives.id", index=True)
    objective_revision_id: UUID = Field(foreign_key="objective_revisions.id")
    activity_template_id: UUID | None = Field(default=None, foreign_key="learning_activities.id")
    scheduler_version: str
    fsrs_state: dict = Field(default_factory=dict, sa_column=Column(JSONB, nullable=False))
    due_at: datetime = Field(sa_column=Column(DateTime(timezone=True), nullable=False))
    status: str = "active"
    superseded_by: UUID | None = Field(default=None, foreign_key="review_items.id")


class ReviewEvent(SQLModel, table=True):
    __tablename__ = "review_events"

    id: UUID = Field(default_factory=uuid4, primary_key=True)
    review_item_id: UUID = Field(foreign_key="review_items.id", index=True)
    attempt_id: UUID | None = Field(default=None, foreign_key="assessment_attempts.id")
    rating: str
    reviewed_at: datetime = Field(default_factory=utcnow, sa_column=Column(DateTime(timezone=True), nullable=False))
    scheduler_version: str
    before_state: dict = Field(default_factory=dict, sa_column=Column(JSONB, nullable=False))
    after_state: dict = Field(default_factory=dict, sa_column=Column(JSONB, nullable=False))
    rating_overridden: bool = False
