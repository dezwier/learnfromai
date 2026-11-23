"""Per-user thumbs feedback on quiz bits.

Revision ID: t8j4n1l35o92
Revises: s7i3m0k24n81
Create Date: 2026-11-23 23:50:00.000000
"""

from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op

revision: str = "t8j4n1l35o92"
down_revision: Union[str, None] = "s7i3m0k24n81"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.create_table(
        "quiz_bit_feedback",
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column("user_id", sa.Uuid(), nullable=False),
        sa.Column("bit_id", sa.Uuid(), nullable=False),
        sa.Column("rating", sa.Integer(), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False),
        sa.ForeignKeyConstraint(["bit_id"], ["knowledge_bits.id"], ondelete="CASCADE"),
        sa.ForeignKeyConstraint(["user_id"], ["users.id"], ondelete="CASCADE"),
        sa.PrimaryKeyConstraint("id"),
        sa.UniqueConstraint("user_id", "bit_id", name="uq_quiz_bit_feedback_user_bit"),
    )
    op.create_index(
        "ix_quiz_bit_feedback_user_id", "quiz_bit_feedback", ["user_id"], unique=False
    )
    op.create_index(
        "ix_quiz_bit_feedback_bit_id", "quiz_bit_feedback", ["bit_id"], unique=False
    )


def downgrade() -> None:
    op.drop_index("ix_quiz_bit_feedback_bit_id", table_name="quiz_bit_feedback")
    op.drop_index("ix_quiz_bit_feedback_user_id", table_name="quiz_bit_feedback")
    op.drop_table("quiz_bit_feedback")
