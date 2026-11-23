"""Persisted daily cron run summaries and admin ranking overrides."""

from __future__ import annotations

from datetime import datetime
from uuid import UUID, uuid4

from sqlalchemy import Column, DateTime, Float, Integer, Text
from sqlalchemy.dialects.postgresql import JSONB
from sqlmodel import Field, SQLModel

from app.core.time import utcnow


class CronRun(SQLModel, table=True):
    """One daily ranking cron execution and the jobs it enqueued."""

    __tablename__ = "cron_runs"

    id: UUID = Field(default_factory=uuid4, primary_key=True)
    status: str = Field(default="running", sa_column=Column(Text, nullable=False))
    started_at: datetime = Field(
        default_factory=utcnow,
        sa_column=Column(DateTime(timezone=True), nullable=False, index=True),
    )
    finished_at: datetime | None = Field(
        default=None,
        sa_column=Column(DateTime(timezone=True), nullable=True),
    )
    neighbor_jobs: list = Field(default_factory=list, sa_column=Column(JSONB, nullable=False))
    learn_jobs: list = Field(default_factory=list, sa_column=Column(JSONB, nullable=False))
    weights_snapshot: dict = Field(default_factory=dict, sa_column=Column(JSONB, nullable=False))
    error: str | None = Field(default=None, sa_column=Column(Text, nullable=True))


class RankingConfig(SQLModel, table=True):
    """Singleton row: admin overrides for cron fill weights (id=1)."""

    __tablename__ = "ranking_config"

    id: int = Field(default=1, sa_column=Column(Integer, primary_key=True))
    neighbor_w_fill: float | None = Field(
        default=None, sa_column=Column(Float, nullable=True)
    )
    learn_w_fill: float | None = Field(
        default=None, sa_column=Column(Float, nullable=True)
    )
    updated_at: datetime = Field(
        default_factory=utcnow,
        sa_column=Column(DateTime(timezone=True), nullable=False),
    )
