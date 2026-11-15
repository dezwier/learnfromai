"""Add image_thumb_bytes on knowledge_nodes.

Revision ID: j8f4d1b35e92
Revises: i7e3c0a24d81
Create Date: 2026-11-15 14:50:00.000000
"""

from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op

revision: str = "j8f4d1b35e92"
down_revision: Union[str, None] = "i7e3c0a24d81"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.add_column("knowledge_nodes", sa.Column("image_thumb_bytes", sa.LargeBinary(), nullable=True))


def downgrade() -> None:
    op.drop_column("knowledge_nodes", "image_thumb_bytes")
