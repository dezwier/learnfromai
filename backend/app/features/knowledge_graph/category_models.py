from __future__ import annotations

from datetime import datetime
from uuid import UUID, uuid4

from sqlalchemy import BigInteger, Column, DateTime
from sqlmodel import Field, SQLModel


class KnowledgeCategory(SQLModel, table=True):
    """One Wikipedia category, shared by every topic that reaches it."""

    __tablename__ = "knowledge_categories"

    id: UUID = Field(default_factory=uuid4, primary_key=True)
    wikipedia_page_id: int = Field(sa_column=Column(BigInteger, nullable=False, unique=True, index=True))
    title: str
    description: str | None = None
    upstream_fetched_at: datetime | None = Field(
        default=None,
        sa_column=Column(DateTime(timezone=True), nullable=True),
    )
    upstream_complete: bool = False
    downstream_fetched_at: datetime | None = Field(
        default=None,
        sa_column=Column(DateTime(timezone=True), nullable=True),
    )
    downstream_complete: bool = False


class KnowledgeCategoryEdge(SQLModel, table=True):
    """A parent category contains a child category. A child may have several parents."""

    __tablename__ = "knowledge_category_edges"

    parent_category_id: UUID = Field(foreign_key="knowledge_categories.id", primary_key=True)
    child_category_id: UUID = Field(foreign_key="knowledge_categories.id", primary_key=True)
