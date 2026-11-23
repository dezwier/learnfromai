"""Singleton ranking_config for admin-tunable cron fill weights.

Revision ID: s7i3m0k24n81
Revises: r6h2l9j13m70
Create Date: 2026-11-23 23:30:00.000000
"""

from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op

revision: str = "s7i3m0k24n81"
down_revision: Union[str, None] = "r6h2l9j13m70"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.create_table(
        "ranking_config",
        sa.Column("id", sa.Integer(), nullable=False),
        sa.Column("neighbor_w_fill", sa.Float(), nullable=True),
        sa.Column("learn_w_fill", sa.Float(), nullable=True),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False),
        sa.PrimaryKeyConstraint("id"),
    )


def downgrade() -> None:
    op.drop_table("ranking_config")
