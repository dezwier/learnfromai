"""Per-user Leitner state for completed atomic learning packs."""

from __future__ import annotations

from datetime import datetime
from uuid import UUID, uuid4

from sqlalchemy import Column, DateTime, ForeignKey, Integer, UniqueConstraint
from sqlmodel import Field, SQLModel

from app.core.time import utcnow

GRADUATION_BIN = 8
# Hours until next review after landing in bins 1..7.
LEITNER_INTERVALS_HOURS = (3, 12, 24, 48, 96, 168, 336)
LEITNER_BIN_8_HOURS = 672  # 4 weeks; each higher bin adds (672 - 336) = 336h


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
