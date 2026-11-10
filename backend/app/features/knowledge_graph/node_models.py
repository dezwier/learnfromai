from __future__ import annotations

from datetime import datetime
from uuid import UUID, uuid4

from sqlalchemy import BigInteger, Column, DateTime, ForeignKey, Integer, Text
from sqlmodel import Field, SQLModel

from app.core.time import utcnow


class KnowledgeNode(SQLModel, table=True):
    """One Wikidata item. Identity is the Q number."""

    __tablename__ = "knowledge_nodes"

    qid: int = Field(sa_column=Column(BigInteger, primary_key=True))
    title: str
    description: str | None = None
    enwiki_title: str | None = None
    domain_qid: int | None = Field(default=None, sa_column=Column(BigInteger, nullable=True))
    upstream_fetched_at: datetime | None = Field(default=None, sa_column=Column(DateTime(timezone=True), nullable=True))
    upstream_complete: bool = False
    downstream_fetched_at: datetime | None = Field(default=None, sa_column=Column(DateTime(timezone=True), nullable=True))
    downstream_complete: bool = False
    related_fetched_at: datetime | None = Field(default=None, sa_column=Column(DateTime(timezone=True), nullable=True))
    related_complete: bool = False


class KnowledgeEdge(SQLModel, table=True):
    """Typed edge between two Wikidata items."""

    __tablename__ = "knowledge_edges"

    from_qid: int = Field(sa_column=Column(BigInteger, ForeignKey("knowledge_nodes.qid"), primary_key=True))
    relation: str = Field(sa_column=Column(Text, primary_key=True))
    to_qid: int = Field(sa_column=Column(BigInteger, ForeignKey("knowledge_nodes.qid"), primary_key=True))


class KnowledgeRequest(SQLModel, table=True):
    """One signed-in focus on the shared graph."""

    __tablename__ = "knowledge_requests"

    id: UUID = Field(default_factory=uuid4, primary_key=True)
    user_id: UUID = Field(foreign_key="users.id", index=True)
    focus_qid: int = Field(sa_column=Column(BigInteger, ForeignKey("knowledge_nodes.qid"), index=True))
    up_depth: int = 1
    down_depth: int = 1
    cloud_radius: int = 1
    created_at: datetime = Field(default_factory=utcnow, sa_column=Column(DateTime(timezone=True), nullable=False))


class KnowledgeRequestNode(SQLModel, table=True):
    """How far a node sits from this request's focus."""

    __tablename__ = "knowledge_request_nodes"

    request_id: UUID = Field(sa_column=Column(ForeignKey("knowledge_requests.id"), primary_key=True))
    qid: int = Field(sa_column=Column(BigInteger, ForeignKey("knowledge_nodes.qid"), primary_key=True))
    distance: int = Field(sa_column=Column(Integer, nullable=False))
