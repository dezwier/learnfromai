"""Append-only user–topic interaction event store."""

from __future__ import annotations

from datetime import datetime
from uuid import UUID, uuid4

from sqlalchemy import Column, DateTime, ForeignKey, Index, Text
from sqlalchemy.dialects.postgresql import JSONB
from sqlmodel import Field, SQLModel

from app.core.time import utcnow

EVENT_KINDS = ("focus", "learn", "example", "check1", "check2", "check3")
CLIENT_EVENT_KINDS = ("learn", "example", "check1", "check2", "check3")
CHECK_EVENT_KINDS = ("check1", "check2", "check3")
MAX_EVENTS_PER_REQUEST = 50


class UserTopicEvent(SQLModel, table=True):
    """One user interaction with a knowledge topic (focus / learn / check / …)."""

    __tablename__ = "user_topic_events"
    __table_args__ = (
        Index("ix_user_topic_events_user_occurred", "user_id", "occurred_at"),
        Index("ix_user_topic_events_node_kind_occurred", "node_id", "kind", "occurred_at"),
    )

    id: UUID = Field(default_factory=uuid4, primary_key=True)
    user_id: UUID = Field(sa_column=Column(ForeignKey("users.id"), nullable=False, index=True))
    node_id: UUID = Field(
        sa_column=Column(ForeignKey("knowledge_nodes.id"), nullable=False, index=True)
    )
    kind: str = Field(sa_column=Column(Text, nullable=False))
    payload: dict = Field(default_factory=dict, sa_column=Column(JSONB, nullable=False))
    occurred_at: datetime = Field(
        default_factory=utcnow,
        sa_column=Column(DateTime(timezone=True), nullable=False),
    )
    created_at: datetime = Field(
        default_factory=utcnow,
        sa_column=Column(DateTime(timezone=True), nullable=False),
    )
