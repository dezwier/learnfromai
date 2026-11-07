from __future__ import annotations

from datetime import datetime
from uuid import UUID, uuid4

from sqlalchemy import Column, DateTime, ForeignKey, Index, UniqueConstraint, text
from sqlalchemy.dialects.postgresql import JSONB
from sqlalchemy.dialects.postgresql import UUID as PGUUID
from sqlmodel import Field, SQLModel

from app.core.time import utcnow


class Graph(SQLModel, table=True):
    __tablename__ = "graphs"

    id: UUID = Field(default_factory=uuid4, primary_key=True)
    slug: str = Field(index=True)
    title: str
    owner_user_id: UUID | None = Field(default=None, foreign_key="users.id", index=True)
    visibility: str = "private"
    active_release_id: UUID | None = Field(
        default=None,
        sa_column=Column(
            PGUUID(as_uuid=True),
            ForeignKey("graph_releases.id", use_alter=True, name="fk_graphs_active_release"),
            nullable=True,
        ),
    )
    created_at: datetime = Field(default_factory=utcnow, sa_column=Column(DateTime(timezone=True), nullable=False))


class Concept(SQLModel, table=True):
    __tablename__ = "concepts"

    id: UUID = Field(default_factory=uuid4, primary_key=True)
    canonical_key: str | None = Field(default=None, index=True)
    origin_graph_id: UUID = Field(foreign_key="graphs.id", index=True)
    scope: str = "domain"
    created_at: datetime = Field(default_factory=utcnow, sa_column=Column(DateTime(timezone=True), nullable=False))


class ConceptRevision(SQLModel, table=True):
    __tablename__ = "concept_revisions"
    __table_args__ = (UniqueConstraint("concept_id", "revision_no", name="uq_concept_revision_no"),)

    id: UUID = Field(default_factory=uuid4, primary_key=True)
    concept_id: UUID = Field(foreign_key="concepts.id", index=True)
    revision_no: int
    title: str
    summary: str
    knowledge_type: str
    semantic_fingerprint: str
    change_kind: str
    source_status: str
    status: str = "published"
    creator: str = "system"
    created_at: datetime = Field(default_factory=utcnow, sa_column=Column(DateTime(timezone=True), nullable=False))


class LearningObjective(SQLModel, table=True):
    __tablename__ = "learning_objectives"

    id: UUID = Field(default_factory=uuid4, primary_key=True)
    origin_concept_id: UUID = Field(foreign_key="concepts.id", index=True)
    status: str = "active"
    created_at: datetime = Field(default_factory=utcnow, sa_column=Column(DateTime(timezone=True), nullable=False))


class ObjectiveRevision(SQLModel, table=True):
    __tablename__ = "objective_revisions"
    __table_args__ = (UniqueConstraint("objective_id", "revision_no", name="uq_objective_revision_no"),)

    id: UUID = Field(default_factory=uuid4, primary_key=True)
    objective_id: UUID = Field(foreign_key="learning_objectives.id", index=True)
    concept_revision_id: UUID = Field(foreign_key="concept_revisions.id", index=True)
    revision_no: int
    statement: str
    success_criteria: dict = Field(default_factory=dict, sa_column=Column(JSONB, nullable=False))
    cognitive_dimension: str
    semantic_fingerprint: str
    created_at: datetime = Field(default_factory=utcnow, sa_column=Column(DateTime(timezone=True), nullable=False))


class Edge(SQLModel, table=True):
    __tablename__ = "edges"

    id: UUID = Field(default_factory=uuid4, primary_key=True)
    graph_id: UUID = Field(foreign_key="graphs.id", index=True)
    created_at: datetime = Field(default_factory=utcnow, sa_column=Column(DateTime(timezone=True), nullable=False))


class EdgeRevision(SQLModel, table=True):
    __tablename__ = "edge_revisions"
    __table_args__ = (
        UniqueConstraint("edge_id", "revision_no", name="uq_edge_revision_no"),
        Index("ix_edge_revisions_endpoints", "from_concept_id", "to_concept_id", "type"),
    )

    id: UUID = Field(default_factory=uuid4, primary_key=True)
    edge_id: UUID = Field(foreign_key="edges.id", index=True)
    revision_no: int
    from_concept_id: UUID = Field(foreign_key="concepts.id")
    to_concept_id: UUID = Field(foreign_key="concepts.id")
    type: str
    is_primary_parent: bool = False
    created_at: datetime = Field(default_factory=utcnow, sa_column=Column(DateTime(timezone=True), nullable=False))


class GraphOverlay(SQLModel, table=True):
    __tablename__ = "graph_overlays"

    id: UUID = Field(default_factory=uuid4, primary_key=True)
    base_graph_id: UUID = Field(foreign_key="graphs.id", index=True)
    owner_user_id: UUID = Field(foreign_key="users.id", index=True)
    base_release_id: UUID = Field(
        sa_column=Column(
            PGUUID(as_uuid=True),
            ForeignKey("graph_releases.id", use_alter=True, name="fk_overlay_base_release"),
            nullable=False,
        )
    )
    active_private_release_id: UUID | None = Field(
        default=None,
        sa_column=Column(
            PGUUID(as_uuid=True),
            ForeignKey("graph_releases.id", use_alter=True, name="fk_overlay_active_release"),
            nullable=True,
        ),
    )
    status: str = "active"
    created_at: datetime = Field(default_factory=utcnow, sa_column=Column(DateTime(timezone=True), nullable=False))


class GraphRelease(SQLModel, table=True):
    __tablename__ = "graph_releases"
    __table_args__ = (
        Index(
            "uq_release_shared_version",
            "graph_id",
            "version",
            unique=True,
            postgresql_where=text("overlay_id IS NULL"),
        ),
        Index(
            "uq_release_overlay_version",
            "graph_id",
            "overlay_id",
            "version",
            unique=True,
            postgresql_where=text("overlay_id IS NOT NULL"),
        ),
    )

    id: UUID = Field(default_factory=uuid4, primary_key=True)
    graph_id: UUID = Field(foreign_key="graphs.id", index=True)
    version: int
    parent_release_id: UUID | None = Field(default=None, foreign_key="graph_releases.id")
    overlay_id: UUID | None = Field(default=None, foreign_key="graph_overlays.id", index=True)
    checksum: str
    status: str = "published"
    published_at: datetime = Field(default_factory=utcnow, sa_column=Column(DateTime(timezone=True), nullable=False))
    published_by: UUID | None = Field(default=None, foreign_key="users.id")
    change_proposal_id: UUID | None = Field(
        default=None,
        sa_column=Column(
            PGUUID(as_uuid=True),
            ForeignKey("graph_change_proposals.id", use_alter=True, name="fk_release_proposal"),
            nullable=True,
        ),
    )


class ReleaseConcept(SQLModel, table=True):
    __tablename__ = "release_concepts"
    __table_args__ = (Index("ix_release_concepts_release_concept", "release_id", "concept_id"),)

    release_id: UUID = Field(foreign_key="graph_releases.id", primary_key=True)
    concept_id: UUID = Field(foreign_key="concepts.id", primary_key=True)
    concept_revision_id: UUID = Field(foreign_key="concept_revisions.id")


class ReleaseEdge(SQLModel, table=True):
    __tablename__ = "release_edges"

    release_id: UUID = Field(foreign_key="graph_releases.id", primary_key=True)
    edge_id: UUID = Field(foreign_key="edges.id", primary_key=True)
    edge_revision_id: UUID = Field(foreign_key="edge_revisions.id")


class SourceDocument(SQLModel, table=True):
    __tablename__ = "source_documents"

    id: UUID = Field(default_factory=uuid4, primary_key=True)
    source_url: str
    title: str
    publisher: str | None = None
    retrieved_at: datetime = Field(default_factory=utcnow, sa_column=Column(DateTime(timezone=True), nullable=False))
    published_at: datetime | None = Field(default=None, sa_column=Column(DateTime(timezone=True), nullable=True))
    content_hash: str
    trust_tier: str = "source_pending"
    license: str | None = None


class SourceClaim(SQLModel, table=True):
    __tablename__ = "source_claims"

    id: UUID = Field(default_factory=uuid4, primary_key=True)
    source_id: UUID = Field(foreign_key="source_documents.id", index=True)
    concept_revision_id: UUID = Field(foreign_key="concept_revisions.id", index=True)
    claim_key: str
    support_status: str = "source_pending"
