"""Clear Wikidata fetch markers so neighborhoods are read again.

Revision ID: b8d5f1a30c91
Revises: a7c4e9b12f80
Create Date: 2026-11-10 20:35:00.000000
"""

from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op

revision: str = "b8d5f1a30c91"
down_revision: Union[str, None] = "a7c4e9b12f80"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.execute(
        sa.text(
            """
            UPDATE knowledge_items
            SET upstream_complete = false,
                downstream_complete = false,
                upstream_fetched_at = NULL,
                downstream_fetched_at = NULL
            """
        )
    )


def downgrade() -> None:
    pass
