"""Store Wikidata items as the shared knowledge graph.

Revision ID: a7c4e9b12f80
Revises: f3a8c2d91e40
Create Date: 2026-11-10 20:05:00.000000
"""

from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op

revision: str = "a7c4e9b12f80"
down_revision: Union[str, None] = "f3a8c2d91e40"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.drop_index("ix_knowledge_graph_requests_focus_category_id", table_name="knowledge_graph_requests")
    op.drop_index("ix_knowledge_graph_requests_user_id", table_name="knowledge_graph_requests")
    op.drop_table("knowledge_graph_requests")
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
    op.create_index("ix_knowledge_item_edges_child_item_id", "knowledge_item_edges", ["child_item_id"])
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
    op.create_index("ix_knowledge_graph_requests_user_id", "knowledge_graph_requests", ["user_id"])
    op.create_index("ix_knowledge_graph_requests_focus_item_id", "knowledge_graph_requests", ["focus_item_id"])
    op.create_table(
        "knowledge_graph_request_nodes",
        sa.Column("request_id", sa.Uuid(), nullable=False),
        sa.Column("item_id", sa.Uuid(), nullable=False),
        sa.Column("distance", sa.Integer(), nullable=False),
        sa.ForeignKeyConstraint(["item_id"], ["knowledge_items.id"]),
        sa.ForeignKeyConstraint(["request_id"], ["knowledge_graph_requests.id"]),
        sa.PrimaryKeyConstraint("request_id", "item_id"),
    )
    op.create_index("ix_knowledge_graph_request_nodes_item_id", "knowledge_graph_request_nodes", ["item_id"])


def downgrade() -> None:
    op.drop_index("ix_knowledge_graph_request_nodes_item_id", table_name="knowledge_graph_request_nodes")
    op.drop_table("knowledge_graph_request_nodes")
    op.drop_index("ix_knowledge_graph_requests_focus_item_id", table_name="knowledge_graph_requests")
    op.drop_index("ix_knowledge_graph_requests_user_id", table_name="knowledge_graph_requests")
    op.drop_table("knowledge_graph_requests")
    op.drop_index("ix_knowledge_item_edges_child_item_id", table_name="knowledge_item_edges")
    op.drop_table("knowledge_item_edges")
    op.drop_index("uq_knowledge_items_wikidata_qid", table_name="knowledge_items")
    op.drop_table("knowledge_items")
    op.create_table(
        "knowledge_graph_requests",
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column("user_id", sa.Uuid(), nullable=False),
        sa.Column("focus_category_id", sa.Uuid(), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.ForeignKeyConstraint(["focus_category_id"], ["knowledge_categories.id"]),
        sa.ForeignKeyConstraint(["user_id"], ["users.id"]),
        sa.PrimaryKeyConstraint("id"),
    )
    op.create_index("ix_knowledge_graph_requests_user_id", "knowledge_graph_requests", ["user_id"])
    op.create_index(
        "ix_knowledge_graph_requests_focus_category_id",
        "knowledge_graph_requests",
        ["focus_category_id"],
    )
