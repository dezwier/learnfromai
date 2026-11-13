from __future__ import annotations

from datetime import datetime
from uuid import UUID, uuid4

from sqlalchemy import Column, DateTime, Index, text
from sqlalchemy.dialects.postgresql import JSONB
from sqlmodel import Field, SQLModel

from app.core.time import utcnow


class GenerationJob(SQLModel, table=True):
    __tablename__ = "generation_jobs"
    __table_args__ = (
        Index("ix_generation_jobs_claim", "state", "lease_until"),
        Index(
            "uq_generation_jobs_user_key",
            "user_id",
            "idempotency_key",
            unique=True,
            postgresql_where=text("idempotency_key IS NOT NULL AND user_id IS NOT NULL"),
        ),
        Index(
            "uq_generation_jobs_system_key",
            "idempotency_key",
            unique=True,
            postgresql_where=text("idempotency_key IS NOT NULL AND user_id IS NULL"),
        ),
    )

    id: UUID = Field(default_factory=uuid4, primary_key=True)
    user_id: UUID | None = Field(default=None, foreign_key="users.id", index=True)
    type: str
    state: str = "queued"
    payload: dict = Field(default_factory=dict, sa_column=Column(JSONB, nullable=False))
    result: dict | None = Field(default=None, sa_column=Column(JSONB, nullable=True))
    progress: dict = Field(default_factory=dict, sa_column=Column(JSONB, nullable=False))
    attempts: int = 0
    max_attempts: int = 5
    lease_until: datetime | None = Field(default=None, sa_column=Column(DateTime(timezone=True), nullable=True))
    lease_token: UUID | None = None
    idempotency_key: str | None = None
    error_code: str | None = None
    error_message: str | None = None
    created_at: datetime = Field(default_factory=utcnow, sa_column=Column(DateTime(timezone=True), nullable=False))
    updated_at: datetime = Field(default_factory=utcnow, sa_column=Column(DateTime(timezone=True), nullable=False))


class GenerationJobWatcher(SQLModel, table=True):
    """Users who care about a shared expand job (badge / job list)."""

    __tablename__ = "generation_job_watchers"
    __table_args__ = (
        Index("uq_generation_job_watchers_job_user", "job_id", "user_id", unique=True),
        Index("ix_generation_job_watchers_user", "user_id"),
    )

    id: UUID = Field(default_factory=uuid4, primary_key=True)
    job_id: UUID = Field(foreign_key="generation_jobs.id", index=True)
    user_id: UUID = Field(foreign_key="users.id", index=True)
    node_id: UUID = Field(foreign_key="knowledge_nodes.id", index=True)
    title: str = Field(default="", max_length=512)
    created_at: datetime = Field(default_factory=utcnow, sa_column=Column(DateTime(timezone=True), nullable=False))


class LlmUsage(SQLModel, table=True):
    __tablename__ = "llm_usage"

    id: UUID = Field(default_factory=uuid4, primary_key=True)
    user_id: UUID | None = Field(default=None, foreign_key="users.id", index=True)
    job_id: UUID | None = Field(default=None, foreign_key="generation_jobs.id")
    task: str
    provider: str
    model: str
    input_tokens: int = 0
    output_tokens: int = 0
    estimated_cost_usd: float = 0.0
    created_at: datetime = Field(default_factory=utcnow, sa_column=Column(DateTime(timezone=True), nullable=False))


class WorkerHeartbeat(SQLModel, table=True):
    __tablename__ = "worker_heartbeats"

    id: str = Field(primary_key=True)
    beat_at: datetime = Field(sa_column=Column(DateTime(timezone=True), nullable=False))
