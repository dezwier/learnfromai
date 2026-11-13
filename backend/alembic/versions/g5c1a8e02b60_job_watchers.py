"""Add generation_job_watchers for shared expand jobs.

Revision ID: a5c1a8e02b60
Revises: f4b9d2e01a50
Create Date: 2026-11-13 10:55:00.000000
"""

from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op

revision: str = "a5c1a8e02b60"
down_revision: Union[str, None] = "f4b9d2e01a50"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.create_table(
        "generation_job_watchers",
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column("job_id", sa.Uuid(), nullable=False),
        sa.Column("user_id", sa.Uuid(), nullable=False),
        sa.Column("node_id", sa.Uuid(), nullable=False),
        sa.Column("title", sa.String(length=512), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.ForeignKeyConstraint(["job_id"], ["generation_jobs.id"]),
        sa.ForeignKeyConstraint(["user_id"], ["users.id"]),
        sa.ForeignKeyConstraint(["node_id"], ["knowledge_nodes.id"]),
        sa.PrimaryKeyConstraint("id"),
    )
    op.create_index("ix_generation_job_watchers_job_id", "generation_job_watchers", ["job_id"])
    op.create_index("ix_generation_job_watchers_user_id", "generation_job_watchers", ["user_id"])
    op.create_index("ix_generation_job_watchers_node_id", "generation_job_watchers", ["node_id"])
    op.create_index(
        "uq_generation_job_watchers_job_user",
        "generation_job_watchers",
        ["job_id", "user_id"],
        unique=True,
    )
    op.create_index("ix_generation_job_watchers_user", "generation_job_watchers", ["user_id"])


def downgrade() -> None:
    op.drop_index("ix_generation_job_watchers_user", table_name="generation_job_watchers")
    op.drop_index("uq_generation_job_watchers_job_user", table_name="generation_job_watchers")
    op.drop_index("ix_generation_job_watchers_node_id", table_name="generation_job_watchers")
    op.drop_index("ix_generation_job_watchers_user_id", table_name="generation_job_watchers")
    op.drop_index("ix_generation_job_watchers_job_id", table_name="generation_job_watchers")
    op.drop_table("generation_job_watchers")
