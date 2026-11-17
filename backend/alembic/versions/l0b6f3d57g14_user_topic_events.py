"""Add user_topic_events for learner interaction log.

Revision ID: l0b6f3d57g14
Revises: k9a5e2c46f03
Create Date: 2026-11-17 11:15:00.000000
"""

from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

revision: str = "l0b6f3d57g14"
down_revision: Union[str, None] = "k9a5e2c46f03"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.create_table(
        "user_topic_events",
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column("user_id", sa.Uuid(), nullable=False),
        sa.Column("node_id", sa.Uuid(), nullable=False),
        sa.Column("kind", sa.Text(), nullable=False),
        sa.Column("payload", postgresql.JSONB(astext_type=sa.Text()), nullable=False),
        sa.Column("occurred_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.ForeignKeyConstraint(["user_id"], ["users.id"]),
        sa.ForeignKeyConstraint(["node_id"], ["knowledge_nodes.id"]),
        sa.PrimaryKeyConstraint("id"),
    )
    op.create_index("ix_user_topic_events_user_id", "user_topic_events", ["user_id"])
    op.create_index("ix_user_topic_events_node_id", "user_topic_events", ["node_id"])
    op.create_index(
        "ix_user_topic_events_user_occurred",
        "user_topic_events",
        ["user_id", "occurred_at"],
    )
    op.create_index(
        "ix_user_topic_events_node_kind_occurred",
        "user_topic_events",
        ["node_id", "kind", "occurred_at"],
    )


def downgrade() -> None:
    op.drop_index("ix_user_topic_events_node_kind_occurred", table_name="user_topic_events")
    op.drop_index("ix_user_topic_events_user_occurred", table_name="user_topic_events")
    op.drop_index("ix_user_topic_events_node_id", table_name="user_topic_events")
    op.drop_index("ix_user_topic_events_user_id", table_name="user_topic_events")
    op.drop_table("user_topic_events")
