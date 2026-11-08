"""Flatten the graph to nodes, edges, and extend requests.

Revision ID: b7e2c4a91d03
Revises: a1c0e5b79d22
Create Date: 2026-11-08 04:20:00.000000
"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


revision: str = "b7e2c4a91d03"
down_revision: Union[str, None] = "a1c0e5b79d22"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.add_column("concepts", sa.Column("title", sa.Text(), nullable=True))
    op.add_column("concepts", sa.Column("summary", sa.Text(), nullable=True))
    op.add_column("edges", sa.Column("from_concept_id", sa.Uuid(), nullable=True))
    op.add_column("edges", sa.Column("to_concept_id", sa.Uuid(), nullable=True))
    op.add_column("edges", sa.Column("type", sa.Text(), nullable=True))
    op.add_column("edges", sa.Column("is_primary_parent", sa.Boolean(), nullable=True))

    op.execute(
        """
        UPDATE concepts AS c
        SET title = picked.title,
            summary = COALESCE(picked.summary, ''),
            origin_graph_id = picked.graph_id
        FROM (
            SELECT DISTINCT ON (rc.concept_id)
                rc.concept_id,
                cr.title,
                cr.summary,
                g.id AS graph_id
            FROM graphs AS g
            JOIN graph_releases AS rel
              ON rel.id = g.active_release_id
             AND rel.overlay_id IS NULL
            JOIN release_concepts AS rc ON rc.release_id = rel.id
            JOIN concept_revisions AS cr ON cr.id = rc.concept_revision_id
            ORDER BY rc.concept_id, (g.slug = 'knowledge') DESC, rel.published_at DESC
        ) AS picked
        WHERE c.id = picked.concept_id
        """
    )
    op.execute(
        """
        UPDATE concepts
        SET title = COALESCE(NULLIF(title, ''), canonical_key, 'Untitled'),
            summary = COALESCE(summary, '')
        WHERE title IS NOT NULL
        """
    )
    op.execute(
        """
        UPDATE edges AS e
        SET from_concept_id = picked.from_concept_id,
            to_concept_id = picked.to_concept_id,
            type = picked.type,
            is_primary_parent = picked.is_primary_parent
        FROM (
            SELECT DISTINCT ON (re.edge_id)
                re.edge_id,
                er.from_concept_id,
                er.to_concept_id,
                er.type,
                er.is_primary_parent
            FROM graphs AS g
            JOIN graph_releases AS rel
              ON rel.id = g.active_release_id
             AND rel.overlay_id IS NULL
            JOIN release_edges AS re ON re.release_id = rel.id
            JOIN edge_revisions AS er ON er.id = re.edge_revision_id
            ORDER BY re.edge_id, (g.slug = 'knowledge') DESC, rel.published_at DESC
        ) AS picked
        WHERE e.id = picked.edge_id
        """
    )

    op.execute("ALTER TABLE graphs DROP CONSTRAINT IF EXISTS fk_graphs_active_release")
    op.execute("ALTER TABLE graph_overlays DROP CONSTRAINT IF EXISTS fk_overlay_active_release")
    op.execute("ALTER TABLE graph_overlays DROP CONSTRAINT IF EXISTS fk_overlay_base_release")
    op.execute("ALTER TABLE graph_releases DROP CONSTRAINT IF EXISTS fk_release_proposal")
    op.execute(
        """
        DROP TABLE IF EXISTS
            review_events,
            review_items,
            mastery_evidence,
            learner_objective_states,
            migration_items,
            migration_runs,
            objective_mappings,
            concept_mappings,
            assessment_attempts,
            activity_objectives,
            learning_activities,
            learning_sessions,
            trajectory_steps,
            trajectory_releases,
            trajectories,
            goal_graphs,
            learning_goals,
            source_claims,
            source_documents,
            release_edges,
            release_concepts,
            objective_revisions,
            learning_objectives,
            graph_change_proposals,
            graph_releases,
            graph_overlays,
            concept_revisions,
            edge_revisions,
            audit_events
        CASCADE
        """
    )

    op.execute("DELETE FROM concepts WHERE title IS NULL")
    op.execute(
        """
        DELETE FROM edges
        WHERE from_concept_id IS NULL
           OR to_concept_id IS NULL
           OR type IS NULL
           OR from_concept_id NOT IN (SELECT id FROM concepts)
           OR to_concept_id NOT IN (SELECT id FROM concepts)
        """
    )
    op.execute(
        """
        DELETE FROM edges AS later
        USING edges AS earlier
        WHERE later.graph_id = earlier.graph_id
          AND later.from_concept_id = earlier.from_concept_id
          AND later.to_concept_id = earlier.to_concept_id
          AND later.type = earlier.type
          AND later.id > earlier.id
        """
    )

    op.alter_column("concepts", "title", nullable=False)
    op.alter_column("concepts", "summary", nullable=False, server_default=sa.text("''"))
    op.alter_column("edges", "from_concept_id", nullable=False)
    op.alter_column("edges", "to_concept_id", nullable=False)
    op.alter_column("edges", "type", nullable=False)
    op.alter_column("edges", "is_primary_parent", nullable=False, server_default=sa.false())
    op.drop_column("concepts", "scope")
    op.drop_index("ix_graphs_owner_user_id", table_name="graphs")
    op.drop_column("graphs", "active_release_id")
    op.drop_column("graphs", "owner_user_id")
    op.drop_column("graphs", "visibility")

    op.create_foreign_key("fk_edges_from_concept", "edges", "concepts", ["from_concept_id"], ["id"])
    op.create_foreign_key("fk_edges_to_concept", "edges", "concepts", ["to_concept_id"], ["id"])
    op.create_index("ix_edges_endpoints", "edges", ["from_concept_id", "to_concept_id", "type"])
    op.create_index(
        "uq_edges_endpoints",
        "edges",
        ["graph_id", "from_concept_id", "to_concept_id", "type"],
        unique=True,
    )

    op.create_table(
        "extend_requests",
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column("user_id", sa.Uuid(), nullable=False),
        sa.Column("graph_id", sa.Uuid(), nullable=False),
        sa.Column("parent_concept_id", sa.Uuid(), nullable=True),
        sa.Column("instruction", sa.Text(), nullable=False),
        sa.Column("status", sa.Text(), nullable=False),
        sa.Column("error_code", sa.Text(), nullable=True),
        sa.Column("truncated", sa.Boolean(), nullable=False, server_default=sa.false()),
        sa.Column("job_id", sa.Uuid(), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("finished_at", sa.DateTime(timezone=True), nullable=True),
        sa.ForeignKeyConstraint(["user_id"], ["users.id"]),
        sa.ForeignKeyConstraint(["graph_id"], ["graphs.id"]),
        sa.ForeignKeyConstraint(["parent_concept_id"], ["concepts.id"]),
        sa.ForeignKeyConstraint(["job_id"], ["generation_jobs.id"]),
        sa.PrimaryKeyConstraint("id"),
    )
    op.create_index("ix_extend_requests_user_id", "extend_requests", ["user_id"])
    op.create_index("ix_extend_requests_graph_id", "extend_requests", ["graph_id"])
    op.create_index("ix_extend_requests_created_at", "extend_requests", ["created_at"])


def downgrade() -> None:
    raise NotImplementedError("Flattening the graph cannot be reversed")
