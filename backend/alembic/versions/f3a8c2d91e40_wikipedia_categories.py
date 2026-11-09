"""Store Wikipedia categories as the shared knowledge graph.

Revision ID: f3a8c2d91e40
Revises: e6b1d4f82c05
Create Date: 2026-11-09 07:20:00.000000
"""

from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op

revision: str = "f3a8c2d91e40"
down_revision: Union[str, None] = "e6b1d4f82c05"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.create_table(
        "knowledge_categories",
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column("wikipedia_page_id", sa.BigInteger(), nullable=False),
        sa.Column("title", sa.Text(), nullable=False),
        sa.Column("description", sa.Text(), nullable=True),
        sa.Column("upstream_fetched_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("upstream_complete", sa.Boolean(), nullable=False, server_default=sa.false()),
        sa.Column("downstream_fetched_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("downstream_complete", sa.Boolean(), nullable=False, server_default=sa.false()),
        sa.PrimaryKeyConstraint("id"),
    )
    op.create_index(
        "uq_knowledge_categories_wikipedia_page_id",
        "knowledge_categories",
        ["wikipedia_page_id"],
        unique=True,
    )
    op.create_table(
        "knowledge_category_edges",
        sa.Column("parent_category_id", sa.Uuid(), nullable=False),
        sa.Column("child_category_id", sa.Uuid(), nullable=False),
        sa.ForeignKeyConstraint(["child_category_id"], ["knowledge_categories.id"]),
        sa.ForeignKeyConstraint(["parent_category_id"], ["knowledge_categories.id"]),
        sa.PrimaryKeyConstraint("parent_category_id", "child_category_id"),
    )
    op.create_index("ix_knowledge_category_edges_child_category_id", "knowledge_category_edges", ["child_category_id"])
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
    op.add_column("concepts", sa.Column("knowledge_category_id", sa.Uuid(), nullable=True))
    op.create_index("ix_concepts_knowledge_category_id", "concepts", ["knowledge_category_id"])
    op.create_foreign_key(
        "fk_concepts_knowledge_category",
        "concepts",
        "knowledge_categories",
        ["knowledge_category_id"],
        ["id"],
        ondelete="SET NULL",
    )


def downgrade() -> None:
    op.drop_constraint("fk_concepts_knowledge_category", "concepts", type_="foreignkey")
    op.drop_index("ix_concepts_knowledge_category_id", table_name="concepts")
    op.drop_column("concepts", "knowledge_category_id")
    op.drop_index("ix_knowledge_graph_requests_focus_category_id", table_name="knowledge_graph_requests")
    op.drop_index("ix_knowledge_graph_requests_user_id", table_name="knowledge_graph_requests")
    op.drop_table("knowledge_graph_requests")
    op.drop_index("ix_knowledge_category_edges_child_category_id", table_name="knowledge_category_edges")
    op.drop_table("knowledge_category_edges")
    op.drop_index("uq_knowledge_categories_wikipedia_page_id", table_name="knowledge_categories")
    op.drop_table("knowledge_categories")
