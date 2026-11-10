"""Rebuild knowledge graph for LLM neighborhoods.

Revision ID: e2a8c4d91f30
Revises: d1f7b3c84e20
Create Date: 2026-11-10 21:40:00.000000
"""

from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op

revision: str = "e2a8c4d91f30"
down_revision: Union[str, None] = "d1f7b3c84e20"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.execute(sa.text("DELETE FROM knowledge_request_nodes"))
    op.execute(sa.text("DELETE FROM knowledge_requests"))
    op.execute(sa.text("DELETE FROM knowledge_edges"))
    op.execute(sa.text("DELETE FROM knowledge_nodes"))

    op.drop_table("knowledge_request_nodes")
    op.drop_table("knowledge_requests")
    op.drop_index("ix_knowledge_edges_to_qid", table_name="knowledge_edges")
    op.drop_table("knowledge_edges")
    op.drop_table("knowledge_nodes")

    op.create_table(
        "knowledge_nodes",
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column("name", sa.Text(), nullable=False),
        sa.Column("name_key", sa.Text(), nullable=False),
        sa.Column("description", sa.Text(), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.PrimaryKeyConstraint("id"),
    )
    op.create_index("ix_knowledge_nodes_name_key", "knowledge_nodes", ["name_key"])
    op.create_table(
        "knowledge_edges",
        sa.Column("from_id", sa.Uuid(), nullable=False),
        sa.Column("relation", sa.Text(), nullable=False),
        sa.Column("to_id", sa.Uuid(), nullable=False),
        sa.ForeignKeyConstraint(["from_id"], ["knowledge_nodes.id"]),
        sa.ForeignKeyConstraint(["to_id"], ["knowledge_nodes.id"]),
        sa.PrimaryKeyConstraint("from_id", "relation", "to_id"),
    )
    op.create_index("ix_knowledge_edges_to_id", "knowledge_edges", ["to_id"])
    op.create_table(
        "knowledge_requests",
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column("user_id", sa.Uuid(), nullable=False),
        sa.Column("focus_id", sa.Uuid(), nullable=False),
        sa.Column("parents", sa.Integer(), nullable=False, server_default="2"),
        sa.Column("siblings", sa.Integer(), nullable=False, server_default="3"),
        sa.Column("children", sa.Integer(), nullable=False, server_default="4"),
        sa.Column("acquaintances", sa.Integer(), nullable=False, server_default="4"),
        sa.Column("job_id", sa.Uuid(), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.ForeignKeyConstraint(["focus_id"], ["knowledge_nodes.id"]),
        sa.ForeignKeyConstraint(["job_id"], ["generation_jobs.id"]),
        sa.ForeignKeyConstraint(["user_id"], ["users.id"]),
        sa.PrimaryKeyConstraint("id"),
    )
    op.create_index("ix_knowledge_requests_user_id", "knowledge_requests", ["user_id"])
    op.create_index("ix_knowledge_requests_focus_id", "knowledge_requests", ["focus_id"])
    op.create_table(
        "knowledge_request_nodes",
        sa.Column("request_id", sa.Uuid(), nullable=False),
        sa.Column("node_id", sa.Uuid(), nullable=False),
        sa.Column("distance", sa.Integer(), nullable=False),
        sa.Column("kind", sa.Text(), nullable=False, server_default="related"),
        sa.ForeignKeyConstraint(["node_id"], ["knowledge_nodes.id"]),
        sa.ForeignKeyConstraint(["request_id"], ["knowledge_requests.id"]),
        sa.PrimaryKeyConstraint("request_id", "node_id"),
    )
    op.create_index("ix_knowledge_request_nodes_node_id", "knowledge_request_nodes", ["node_id"])


def downgrade() -> None:
    op.drop_index("ix_knowledge_request_nodes_node_id", table_name="knowledge_request_nodes")
    op.drop_table("knowledge_request_nodes")
    op.drop_index("ix_knowledge_requests_focus_id", table_name="knowledge_requests")
    op.drop_index("ix_knowledge_requests_user_id", table_name="knowledge_requests")
    op.drop_table("knowledge_requests")
    op.drop_index("ix_knowledge_edges_to_id", table_name="knowledge_edges")
    op.drop_table("knowledge_edges")
    op.drop_index("ix_knowledge_nodes_name_key", table_name="knowledge_nodes")
    op.drop_table("knowledge_nodes")
    op.create_table(
        "knowledge_nodes",
        sa.Column("qid", sa.BigInteger(), nullable=False),
        sa.Column("title", sa.Text(), nullable=False),
        sa.Column("description", sa.Text(), nullable=True),
        sa.Column("enwiki_title", sa.Text(), nullable=True),
        sa.Column("domain_qid", sa.BigInteger(), nullable=True),
        sa.Column("upstream_fetched_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("upstream_complete", sa.Boolean(), nullable=False, server_default=sa.false()),
        sa.Column("downstream_fetched_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("downstream_complete", sa.Boolean(), nullable=False, server_default=sa.false()),
        sa.Column("related_fetched_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("related_complete", sa.Boolean(), nullable=False, server_default=sa.false()),
        sa.PrimaryKeyConstraint("qid"),
    )
    op.create_table(
        "knowledge_edges",
        sa.Column("from_qid", sa.BigInteger(), nullable=False),
        sa.Column("relation", sa.Text(), nullable=False),
        sa.Column("to_qid", sa.BigInteger(), nullable=False),
        sa.ForeignKeyConstraint(["from_qid"], ["knowledge_nodes.qid"]),
        sa.ForeignKeyConstraint(["to_qid"], ["knowledge_nodes.qid"]),
        sa.PrimaryKeyConstraint("from_qid", "relation", "to_qid"),
    )
    op.create_index("ix_knowledge_edges_to_qid", "knowledge_edges", ["to_qid"])
    op.create_table(
        "knowledge_requests",
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column("user_id", sa.Uuid(), nullable=False),
        sa.Column("focus_qid", sa.BigInteger(), nullable=False),
        sa.Column("up_depth", sa.Integer(), nullable=False, server_default="1"),
        sa.Column("down_depth", sa.Integer(), nullable=False, server_default="1"),
        sa.Column("cloud_radius", sa.Integer(), nullable=False, server_default="1"),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.ForeignKeyConstraint(["focus_qid"], ["knowledge_nodes.qid"]),
        sa.ForeignKeyConstraint(["user_id"], ["users.id"]),
        sa.PrimaryKeyConstraint("id"),
    )
    op.create_table(
        "knowledge_request_nodes",
        sa.Column("request_id", sa.Uuid(), nullable=False),
        sa.Column("qid", sa.BigInteger(), nullable=False),
        sa.Column("distance", sa.Integer(), nullable=False),
        sa.ForeignKeyConstraint(["qid"], ["knowledge_nodes.qid"]),
        sa.ForeignKeyConstraint(["request_id"], ["knowledge_requests.id"]),
        sa.PrimaryKeyConstraint("request_id", "qid"),
    )
