"""Optional iconic image for one atomic learning pack."""

from __future__ import annotations

from datetime import datetime
from uuid import UUID, uuid4

from sqlalchemy import Column, DateTime, ForeignKey, Integer, LargeBinary, Text, UniqueConstraint
from sqlmodel import Field, SQLModel

from app.core.time import utcnow


class KnowledgePackImage(SQLModel, table=True):
    """One shared image for a topic pack (node_id + pack_index)."""

    __tablename__ = "knowledge_pack_images"
    __table_args__ = (
        UniqueConstraint(
            "node_id",
            "pack_index",
            name="uq_knowledge_pack_images_node_pack",
        ),
    )

    id: UUID = Field(default_factory=uuid4, primary_key=True)
    node_id: UUID = Field(
        sa_column=Column(ForeignKey("knowledge_nodes.id", ondelete="CASCADE"), nullable=False, index=True)
    )
    pack_index: int = Field(sa_column=Column(Integer, nullable=False))
    image_url: str | None = Field(default=None, sa_column=Column(Text, nullable=True))
    image_bytes: bytes | None = Field(default=None, sa_column=Column(LargeBinary, nullable=True))
    image_thumb_bytes: bytes | None = Field(default=None, sa_column=Column(LargeBinary, nullable=True))
    created_at: datetime = Field(
        default_factory=utcnow,
        sa_column=Column(DateTime(timezone=True), nullable=False),
    )
