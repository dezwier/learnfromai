"""Per-user Leitner state for completed atomic learning packs."""

from __future__ import annotations

from datetime import datetime
from uuid import UUID, uuid4

from sqlalchemy import Column, DateTime, ForeignKey, Integer, UniqueConstraint
from sqlmodel import Field, SQLModel

from app.core.time import utcnow

GRADUATION_BIN = 7
# Hours until next review after landing in bins 1..7.
# 1d, 2d, 4d, 1w, 2w, 3w, 4w
LEITNER_INTERVALS_HOURS = (24, 48, 96, 168, 336, 504, 672)
# Bin 8 = 6 weeks; each higher bin adds 2 weeks (672→1008 step).
LEITNER_BIN_8_HOURS = 1008


class UserPackReview(SQLModel, table=True):
    """Leitner schedule for one user × topic × pack."""

    __tablename__ = "user_pack_reviews"
    __table_args__ = (
        UniqueConstraint(
            "user_id",
            "node_id",
            "pack_index",
            name="uq_user_pack_reviews_user_node_pack",
        ),
    )

    id: UUID = Field(default_factory=uuid4, primary_key=True)
    user_id: UUID = Field(sa_column=Column(ForeignKey("users.id"), nullable=False, index=True))
    node_id: UUID = Field(
        sa_column=Column(ForeignKey("knowledge_nodes.id"), nullable=False, index=True)
    )
    pack_index: int = Field(sa_column=Column(Integer, nullable=False))
    leitner_bin: int = Field(default=0, sa_column=Column(Integer, nullable=False))
    last_review_time: datetime | None = Field(
        default=None,
        sa_column=Column(DateTime(timezone=True), nullable=True),
    )
    next_review_at: datetime | None = Field(
        default=None,
        sa_column=Column(DateTime(timezone=True), nullable=True, index=True),
    )
    graduated_at: datetime | None = Field(
        default=None,
        sa_column=Column(DateTime(timezone=True), nullable=True),
    )
    created_at: datetime = Field(
        default_factory=utcnow,
        sa_column=Column(DateTime(timezone=True), nullable=False),
    )
