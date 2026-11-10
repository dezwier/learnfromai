"""Rebuild the shared graph with qid primary keys.

Revision ID: d1f7b3c84e20
Revises: c9e6a2b41d02
Create Date: 2026-11-10 20:55:00.000000
"""

from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op

revision: str = "d1f7b3c84e20"
down_revision: Union[str, None] = "c9e6a2b41d02"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.execute(sa.text("DELETE FROM knowledge_graph_request_nodes"))
    op.execute(sa.text("DELETE FROM knowledge_graph_requests"))
    op.execute(sa.text("DELETE FROM knowledge_item_edges"))
    op.execute(sa.text("DELETE FROM knowledge_items"))

    op.drop_table("knowledge_graph_request_nodes")
    op.drop_table("knowledge_graph_requests")
    op.drop_table("knowledge_item_edges")
    op.drop_table("knowledge_items")

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
    op.create_index("ix_knowledge_requests_user_id", "knowledge_requests", ["user_id"])
    op.create_index("ix_knowledge_requests_focus_qid", "knowledge_requests", ["focus_qid"])
    op.create_table(
        "knowledge_request_nodes",
        sa.Column("request_id", sa.Uuid(), nullable=False),
        sa.Column("qid", sa.BigInteger(), nullable=False),
        sa.Column("distance", sa.Integer(), nullable=False),
        sa.ForeignKeyConstraint(["qid"], ["knowledge_nodes.qid"]),
        sa.ForeignKeyConstraint(["request_id"], ["knowledge_requests.id"]),
        sa.PrimaryKeyConstraint("request_id", "qid"),
    )
    op.create_index("ix_knowledge_request_nodes_qid", "knowledge_request_nodes", ["qid"])


def downgrade() -> None:
    op.drop_index("ix_knowledge_request_nodes_qid", table_name="knowledge_request_nodes")
    op.drop_table("knowledge_request_nodes")
    op.drop_index("ix_knowledge_requests_focus_qid", table_name="knowledge_requests")
    op.drop_index("ix_knowledge_requests_user_id", table_name="knowledge_requests")
    op.drop_table("knowledge_requests")
    op.drop_index("ix_knowledge_edges_to_qid", table_name="knowledge_edges")
    op.drop_table("knowledge_edges")
    op.drop_table("knowledge_nodes")
    op.create_table(
        "knowledge_items",
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column("wikidata_qid", sa.BigInteger(), nullable=False),
        sa.Column("title", sa.Text(), nullable=False),
        sa.Column("description", sa.Text(), nullable=True),
        sa.Column("domain_qid", sa.BigInteger(), nullable=True),
        sa.Column("upstream_fetched_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("upstream_complete", sa.Boolean(), nullable=False, server_default=sa.false()),
        sa.Column("downstream_fetched_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("downstream_complete", sa.Boolean(), nullable=False, server_default=sa.false()),
        sa.PrimaryKeyConstraint("id"),
    )
    op.create_index("uq_knowledge_items_wikidata_qid", "knowledge_items", ["wikidata_qid"], unique=True)
    op.create_table(
        "knowledge_item_edges",
        sa.Column("parent_item_id", sa.Uuid(), nullable=False),
        sa.Column("child_item_id", sa.Uuid(), nullable=False),
        sa.Column("relation", sa.Text(), nullable=False, server_default="subclass_of"),
        sa.ForeignKeyConstraint(["child_item_id"], ["knowledge_items.id"]),
        sa.ForeignKeyConstraint(["parent_item_id"], ["knowledge_items.id"]),
        sa.PrimaryKeyConstraint("parent_item_id", "child_item_id"),
    )
    op.create_table(
        "knowledge_graph_requests",
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column("user_id", sa.Uuid(), nullable=False),
        sa.Column("focus_item_id", sa.Uuid(), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.ForeignKeyConstraint(["focus_item_id"], ["knowledge_items.id"]),
        sa.ForeignKeyConstraint(["user_id"], ["users.id"]),
        sa.PrimaryKeyConstraint("id"),
    )
    op.create_table(
        "knowledge_graph_request_nodes",
        sa.Column("request_id", sa.Uuid(), nullable=False),
        sa.Column("item_id", sa.Uuid(), nullable=False),
        sa.Column("distance", sa.Integer(), nullable=False),
        sa.ForeignKeyConstraint(["item_id"], ["knowledge_items.id"]),
        sa.ForeignKeyConstraint(["request_id"], ["knowledge_graph_requests.id"]),
        sa.PrimaryKeyConstraint("request_id", "item_id"),
    )
