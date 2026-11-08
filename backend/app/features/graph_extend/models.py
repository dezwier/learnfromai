from __future__ import annotations

from datetime import datetime
from uuid import UUID, uuid4

from sqlalchemy import Column, DateTime
from sqlmodel import Field, SQLModel

from app.core.time import utcnow


class ExtendRequest(SQLModel, table=True):
    __tablename__ = "extend_requests"

    id: UUID = Field(default_factory=uuid4, primary_key=True)
    user_id: UUID = Field(foreign_key="users.id", index=True)
    graph_id: UUID = Field(foreign_key="graphs.id", index=True)
    parent_concept_id: UUID | None = Field(default=None, foreign_key="concepts.id")
    instruction: str
    status: str = "queued"
    error_code: str | None = None
    truncated: bool = False
    job_id: UUID | None = Field(default=None, foreign_key="generation_jobs.id")
    created_at: datetime = Field(default_factory=utcnow, sa_column=Column(DateTime(timezone=True), nullable=False))
    finished_at: datetime | None = Field(default=None, sa_column=Column(DateTime(timezone=True), nullable=True))
