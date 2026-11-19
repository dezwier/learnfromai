"""Shared learning bits attached to knowledge nodes."""

from __future__ import annotations

from datetime import datetime
from uuid import UUID, uuid4

from sqlalchemy import Column, DateTime, ForeignKey, Integer, Text, UniqueConstraint
from sqlalchemy.dialects.postgresql import JSONB
from sqlmodel import Field, SQLModel

from app.core.time import utcnow

RECIPE_VERSION = 1
DEFAULT_BAND = "default"
# One pack = learn + three checks. Legacy rows may still use kind "example" or "check".
CONTENT_KINDS = ("learn", "check1", "check2", "check3")
CHECK_KINDS = ("check1", "check2", "check3")
CHECK_TYPES = ("mc", "true_false", "cloze")
LEGACY_CHECK_KIND = "check"
LEGACY_EXAMPLE_KIND = "example"


class KnowledgeBit(SQLModel, table=True):
    """One typed learning bit for a shared topic pack (learn / example / check / …)."""

    __tablename__ = "knowledge_bits"
    __table_args__ = (
        UniqueConstraint(
            "node_id",
            "pack_index",
            "kind",
            "band",
            "recipe_version",
            name="uq_knowledge_bits_node_pack_kind_band_recipe",
        ),
    )

    id: UUID = Field(default_factory=uuid4, primary_key=True)
    node_id: UUID = Field(sa_column=Column(ForeignKey("knowledge_nodes.id"), nullable=False, index=True))
    pack_index: int = Field(default=1, sa_column=Column(Integer, nullable=False))
    kind: str = Field(sa_column=Column(Text, nullable=False))
    band: str = Field(default=DEFAULT_BAND, sa_column=Column(Text, nullable=False))
    recipe_version: int = Field(default=RECIPE_VERSION, sa_column=Column(Integer, nullable=False))
    position: int = Field(default=0, sa_column=Column(Integer, nullable=False))
    body: dict = Field(default_factory=dict, sa_column=Column(JSONB, nullable=False))
    created_at: datetime = Field(
        default_factory=utcnow,
        sa_column=Column(DateTime(timezone=True), nullable=False),
    )
