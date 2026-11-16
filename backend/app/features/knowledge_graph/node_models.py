from __future__ import annotations

from datetime import datetime
from uuid import UUID, uuid4

from sqlalchemy import Column, DateTime, ForeignKey, Integer, LargeBinary, Text
from sqlmodel import Field, SQLModel

from app.core.time import utcnow


class KnowledgeNode(SQLModel, table=True):
    """One shared topic in the LLM knowledge universe."""

    __tablename__ = "knowledge_nodes"

    id: UUID = Field(default_factory=uuid4, primary_key=True)
    name: str
    name_key: str = Field(index=True)
    description: str | None = None
    # One shared iconic image today (generate or upload). Later: multiple visuals
    # per topic (gallery / testing variants) with a chosen primary for tiles/hero.
    image_url: str | None = Field(default=None, sa_column=Column(Text, nullable=True))
    image_bytes: bytes | None = Field(default=None, sa_column=Column(LargeBinary, nullable=True))
    image_thumb_bytes: bytes | None = Field(default=None, sa_column=Column(LargeBinary, nullable=True))
    created_at: datetime = Field(default_factory=utcnow, sa_column=Column(DateTime(timezone=True), nullable=False))


class KnowledgeEdge(SQLModel, table=True):
    """Typed directed edge. Neighborhood links are stored both ways."""

    __tablename__ = "knowledge_edges"

    from_id: UUID = Field(sa_column=Column(ForeignKey("knowledge_nodes.id"), primary_key=True))
    relation: str = Field(sa_column=Column(Text, primary_key=True))
    to_id: UUID = Field(sa_column=Column(ForeignKey("knowledge_nodes.id"), primary_key=True))


class KnowledgeRequest(SQLModel, table=True):
    """One signed-in focus on the shared graph."""

    __tablename__ = "knowledge_requests"

    id: UUID = Field(default_factory=uuid4, primary_key=True)
    user_id: UUID = Field(foreign_key="users.id", index=True)
    focus_id: UUID = Field(foreign_key="knowledge_nodes.id", index=True)
    parents: int = 2
    siblings: int = 3
    children: int = 4
    acquaintances: int = 4
    job_id: UUID | None = Field(default=None, foreign_key="generation_jobs.id")
    created_at: datetime = Field(default_factory=utcnow, sa_column=Column(DateTime(timezone=True), nullable=False))


class KnowledgeRequestNode(SQLModel, table=True):
    """How far a node sits from this request's focus."""

    __tablename__ = "knowledge_request_nodes"

    request_id: UUID = Field(sa_column=Column(ForeignKey("knowledge_requests.id"), primary_key=True))
    node_id: UUID = Field(sa_column=Column(ForeignKey("knowledge_nodes.id"), primary_key=True))
    distance: int = Field(sa_column=Column(Integer, nullable=False))
    kind: str = Field(default="related", sa_column=Column(Text, nullable=False))
