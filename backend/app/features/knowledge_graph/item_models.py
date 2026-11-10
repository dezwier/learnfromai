from __future__ import annotations

from datetime import datetime
from uuid import UUID, uuid4

from sqlalchemy import BigInteger, Column, DateTime, ForeignKey, Integer, Text
from sqlmodel import Field, SQLModel

from app.core.time import utcnow


class KnowledgeItem(SQLModel, table=True):
    """One Wikidata item, shared by every topic that reaches it."""

    __tablename__ = "knowledge_items"

    id: UUID = Field(default_factory=uuid4, primary_key=True)
    wikidata_qid: int = Field(sa_column=Column(BigInteger, nullable=False, unique=True, index=True))
    title: str
    description: str | None = None
    domain_qid: int | None = Field(default=None, sa_column=Column(BigInteger, nullable=True))
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


class KnowledgeItemEdge(SQLModel, table=True):
    """A parent class or taxon contains a child. One preferred parent is stored per child."""

    __tablename__ = "knowledge_item_edges"

    parent_item_id: UUID = Field(foreign_key="knowledge_items.id", primary_key=True)
    child_item_id: UUID = Field(foreign_key="knowledge_items.id", primary_key=True)
    relation: str = Field(default="subclass_of", sa_column=Column(Text, nullable=False, server_default="subclass_of"))


class KnowledgeGraphRequest(SQLModel, table=True):
    """A signed-in user focused the shared graph on one Wikidata item."""

    __tablename__ = "knowledge_graph_requests"

    id: UUID = Field(default_factory=uuid4, primary_key=True)
    user_id: UUID = Field(foreign_key="users.id", index=True)
    focus_item_id: UUID = Field(foreign_key="knowledge_items.id", index=True)
    created_at: datetime = Field(default_factory=utcnow, sa_column=Column(DateTime(timezone=True), nullable=False))


class KnowledgeGraphRequestNode(SQLModel, table=True):
    """Hop distance from this request's origin to one stored item."""

    __tablename__ = "knowledge_graph_request_nodes"

    request_id: UUID = Field(
        sa_column=Column(ForeignKey("knowledge_graph_requests.id"), primary_key=True),
    )
    item_id: UUID = Field(
        sa_column=Column(ForeignKey("knowledge_items.id"), primary_key=True),
    )
    distance: int = Field(sa_column=Column(Integer, nullable=False))
