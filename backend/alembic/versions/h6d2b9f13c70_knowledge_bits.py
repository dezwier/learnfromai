"""Add knowledge_bits for shared tile content.

Revision ID: h6d2b9f13c70
Revises: a5c1a8e02b60
Create Date: 2026-11-13 23:50:00.000000
"""

from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

revision: str = "h6d2b9f13c70"
down_revision: Union[str, None] = "a5c1a8e02b60"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.create_table(
        "knowledge_bits",
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column("node_id", sa.Uuid(), nullable=False),
        sa.Column("kind", sa.Text(), nullable=False),
        sa.Column("band", sa.Text(), nullable=False),
        sa.Column("recipe_version", sa.Integer(), nullable=False),
        sa.Column("position", sa.Integer(), nullable=False),
        sa.Column("body", postgresql.JSONB(astext_type=sa.Text()), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.ForeignKeyConstraint(["node_id"], ["knowledge_nodes.id"]),
        sa.PrimaryKeyConstraint("id"),
        sa.UniqueConstraint(
            "node_id",
            "kind",
            "band",
            "recipe_version",
            name="uq_knowledge_bits_node_kind_band_recipe",
        ),
    )
    op.create_index("ix_knowledge_bits_node_id", "knowledge_bits", ["node_id"])


def downgrade() -> None:
    op.drop_index("ix_knowledge_bits_node_id", table_name="knowledge_bits")
    op.drop_table("knowledge_bits")
