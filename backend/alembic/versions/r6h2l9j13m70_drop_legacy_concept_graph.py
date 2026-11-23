"""Drop unused Concept / workspace / Wikipedia category tables.

Revision ID: r6h2l9j13m70
Revises: q5g1k8i02l69
Create Date: 2026-11-23 22:55:00.000000
"""

from typing import Sequence, Union

from alembic import op

revision: str = "r6h2l9j13m70"
down_revision: Union[str, None] = "q5g1k8i02l69"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    # Circular FKs between concepts and extend_requests — CASCADE clears them.
    op.execute("DROP TABLE IF EXISTS edges CASCADE")
    op.execute("DROP TABLE IF EXISTS extend_requests CASCADE")
    op.execute("DROP TABLE IF EXISTS concepts CASCADE")
    op.execute("DROP TABLE IF EXISTS knowledge_category_edges CASCADE")
    op.execute("DROP TABLE IF EXISTS knowledge_categories CASCADE")
    op.execute("DROP TABLE IF EXISTS graphs CASCADE")


def downgrade() -> None:
    # Legacy Concept graph is not restored; recreate from older revisions if needed.
    raise NotImplementedError("Legacy Concept / workspace graph cannot be restored")
