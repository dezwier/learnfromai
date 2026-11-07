"""unique concept canonical key

Revision ID: a1c0e5b79d22
Revises: ffe63ea80d8c
Create Date: 2026-11-07 19:55:00.000000
"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


revision: str = "a1c0e5b79d22"
down_revision: Union[str, None] = "ffe63ea80d8c"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.execute(
        """
        UPDATE concepts AS later
        SET canonical_key = NULL
        FROM concepts AS earlier
        WHERE later.canonical_key IS NOT NULL
          AND later.canonical_key = earlier.canonical_key
          AND later.created_at > earlier.created_at
        """
    )
    op.execute(
        """
        UPDATE concepts AS later
        SET canonical_key = NULL
        FROM concepts AS earlier
        WHERE later.canonical_key IS NOT NULL
          AND later.canonical_key = earlier.canonical_key
          AND later.id > earlier.id
        """
    )
    op.create_index(
        "uq_concepts_canonical_key",
        "concepts",
        ["canonical_key"],
        unique=True,
        postgresql_where=sa.text("canonical_key IS NOT NULL"),
    )


def downgrade() -> None:
    op.drop_index("uq_concepts_canonical_key", table_name="concepts")
