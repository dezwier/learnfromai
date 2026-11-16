"""Add photo_bytes on users for uploaded profile pictures.

Revision ID: k9a5e2c46f03
Revises: j8f4d1b35e92
Create Date: 2026-11-16 22:20:00.000000
"""

from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op

revision: str = "k9a5e2c46f03"
down_revision: Union[str, None] = "j8f4d1b35e92"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.add_column("users", sa.Column("photo_bytes", sa.LargeBinary(), nullable=True))


def downgrade() -> None:
    op.drop_column("users", "photo_bytes")
