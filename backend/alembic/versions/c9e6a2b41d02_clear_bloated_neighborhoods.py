"""Clear bloated Wikidata neighborhoods so path-only fetches can rebuild them.

Revision ID: c9e6a2b41d02
Revises: b8d5f1a30c91
Create Date: 2026-11-10 20:40:00.000000
"""

from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op

revision: str = "c9e6a2b41d02"
down_revision: Union[str, None] = "b8d5f1a30c91"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.execute(sa.text("DELETE FROM knowledge_graph_request_nodes"))
    op.execute(sa.text("DELETE FROM knowledge_graph_requests"))
    op.execute(sa.text("DELETE FROM knowledge_item_edges"))
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
