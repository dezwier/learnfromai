"""Add axial hex coords on knowledge nodes.

Revision ID: f4b9d2e01a50
Revises: e2a8c4d91f30
Create Date: 2026-11-11 11:10:00.000000
"""

from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op

revision: str = "f4b9d2e01a50"
down_revision: Union[str, None] = "e2a8c4d91f30"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.add_column("knowledge_nodes", sa.Column("q", sa.Integer(), nullable=True))
    op.add_column("knowledge_nodes", sa.Column("r", sa.Integer(), nullable=True))
    op.add_column("knowledge_nodes", sa.Column("map_depth", sa.Integer(), nullable=True))
    op.create_index("ix_knowledge_nodes_q_r", "knowledge_nodes", ["q", "r"])


def downgrade() -> None:
    op.drop_index("ix_knowledge_nodes_q_r", table_name="knowledge_nodes")
    op.drop_column("knowledge_nodes", "map_depth")
    op.drop_column("knowledge_nodes", "r")
    op.drop_column("knowledge_nodes", "q")
