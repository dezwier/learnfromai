"""Add cron_runs table for daily ranking cron summaries.

Revision ID: n2d8h5f79i36
Revises: m1c7g4e68h25
Create Date: 2026-11-20 10:30:00.000000
"""

from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

revision: str = "n2d8h5f79i36"
down_revision: Union[str, None] = "m1c7g4e68h25"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.create_table(
        "cron_runs",
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column("status", sa.Text(), nullable=False),
        sa.Column("started_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("finished_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("neighbor_jobs", postgresql.JSONB(astext_type=sa.Text()), nullable=False),
        sa.Column("learn_jobs", postgresql.JSONB(astext_type=sa.Text()), nullable=False),
        sa.Column("weights_snapshot", postgresql.JSONB(astext_type=sa.Text()), nullable=False),
        sa.Column("error", sa.Text(), nullable=True),
        sa.PrimaryKeyConstraint("id"),
    )
    op.create_index("ix_cron_runs_started_at", "cron_runs", ["started_at"])


def downgrade() -> None:
    op.drop_index("ix_cron_runs_started_at", table_name="cron_runs")
    op.drop_table("cron_runs")
