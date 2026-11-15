"""Add image_url and image_bytes on knowledge_nodes.

Revision ID: i7e3c0a24d81
Revises: h6d2b9f13c70
Create Date: 2026-11-15 14:30:00.000000
"""

from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op

revision: str = "i7e3c0a24d81"
down_revision: Union[str, None] = "h6d2b9f13c70"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.add_column("knowledge_nodes", sa.Column("image_url", sa.Text(), nullable=True))
    op.add_column("knowledge_nodes", sa.Column("image_bytes", sa.LargeBinary(), nullable=True))


def downgrade() -> None:
    op.drop_column("knowledge_nodes", "image_bytes")
    op.drop_column("knowledge_nodes", "image_url")
