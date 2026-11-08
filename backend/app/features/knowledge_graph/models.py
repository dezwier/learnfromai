from __future__ import annotations

from datetime import datetime
from uuid import UUID, uuid4

from sqlalchemy import Column, DateTime, Index, text
from sqlmodel import Field, SQLModel

from app.core.time import utcnow


class Graph(SQLModel, table=True):
    __tablename__ = "graphs"

    id: UUID = Field(default_factory=uuid4, primary_key=True)
    slug: str = Field(index=True)
    title: str
    created_at: datetime = Field(default_factory=utcnow, sa_column=Column(DateTime(timezone=True), nullable=False))


class Concept(SQLModel, table=True):
    __tablename__ = "concepts"
    __table_args__ = (
        Index(
            "uq_concepts_canonical_key",
            "canonical_key",
            unique=True,
            postgresql_where=text("canonical_key IS NOT NULL"),
        ),
    )

    id: UUID = Field(default_factory=uuid4, primary_key=True)
    canonical_key: str | None = Field(default=None, index=True)
    origin_graph_id: UUID = Field(foreign_key="graphs.id", index=True)
    title: str
    summary: str = ""
    created_at: datetime = Field(default_factory=utcnow, sa_column=Column(DateTime(timezone=True), nullable=False))


class Edge(SQLModel, table=True):
    __tablename__ = "edges"
    __table_args__ = (
        Index("ix_edges_endpoints", "from_concept_id", "to_concept_id", "type"),
        Index("uq_edges_endpoints", "graph_id", "from_concept_id", "to_concept_id", "type", unique=True),
    )

    id: UUID = Field(default_factory=uuid4, primary_key=True)
    graph_id: UUID = Field(foreign_key="graphs.id", index=True)
    from_concept_id: UUID = Field(foreign_key="concepts.id")
    to_concept_id: UUID = Field(foreign_key="concepts.id")
    type: str
    is_primary_parent: bool = False
    created_at: datetime = Field(default_factory=utcnow, sa_column=Column(DateTime(timezone=True), nullable=False))
