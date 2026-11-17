"""Add pack_index to knowledge_bits for atomic learning packs.

Revision ID: m1c7g4e68h25
Revises: l0b6f3d57g14
Create Date: 2026-11-17 16:15:00.000000
"""

from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op

revision: str = "m1c7g4e68h25"
down_revision: Union[str, None] = "l0b6f3d57g14"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.add_column(
        "knowledge_bits",
        sa.Column("pack_index", sa.Integer(), nullable=False, server_default="1"),
    )
    op.drop_constraint(
        "uq_knowledge_bits_node_kind_band_recipe",
        "knowledge_bits",
        type_="unique",
    )
    op.create_unique_constraint(
        "uq_knowledge_bits_node_pack_kind_band_recipe",
        "knowledge_bits",
        ["node_id", "pack_index", "kind", "band", "recipe_version"],
    )
    op.create_index(
        "ix_knowledge_bits_node_id_pack_index",
        "knowledge_bits",
        ["node_id", "pack_index"],
    )


def downgrade() -> None:
    op.drop_index("ix_knowledge_bits_node_id_pack_index", table_name="knowledge_bits")
    op.drop_constraint(
        "uq_knowledge_bits_node_pack_kind_band_recipe",
        "knowledge_bits",
        type_="unique",
    )
    op.create_unique_constraint(
        "uq_knowledge_bits_node_kind_band_recipe",
        "knowledge_bits",
        ["node_id", "kind", "band", "recipe_version"],
    )
    op.drop_column("knowledge_bits", "pack_index")
