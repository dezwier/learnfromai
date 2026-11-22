"""Add knowledge_pack_images for per-pack card images.

Revision ID: q5g1k8i02l69
Revises: p4f0j7h91k58
Create Date: 2026-11-22 13:55:00.000000
"""

from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op

revision: str = "q5g1k8i02l69"
down_revision: Union[str, None] = "p4f0j7h91k58"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.create_table(
        "knowledge_pack_images",
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column("node_id", sa.Uuid(), nullable=False),
        sa.Column("pack_index", sa.Integer(), nullable=False),
        sa.Column("image_url", sa.Text(), nullable=True),
        sa.Column("image_bytes", sa.LargeBinary(), nullable=True),
        sa.Column("image_thumb_bytes", sa.LargeBinary(), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.ForeignKeyConstraint(["node_id"], ["knowledge_nodes.id"], ondelete="CASCADE"),
        sa.PrimaryKeyConstraint("id"),
        sa.UniqueConstraint("node_id", "pack_index", name="uq_knowledge_pack_images_node_pack"),
    )
    op.create_index("ix_knowledge_pack_images_node_id", "knowledge_pack_images", ["node_id"])


def downgrade() -> None:
    op.drop_index("ix_knowledge_pack_images_node_id", table_name="knowledge_pack_images")
    op.drop_table("knowledge_pack_images")
