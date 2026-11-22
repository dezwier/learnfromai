"""Delete legacy free-text cloze quiz bits.

Revision ID: p4f0j7h91k58
Revises: o3e9i6g80j47
Create Date: 2026-11-22 11:20:00.000000
"""

from typing import Sequence, Union

from alembic import op
from sqlmodel import Session

revision: str = "p4f0j7h91k58"
down_revision: Union[str, None] = "o3e9i6g80j47"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    from app.features.content.purge_free_text_cloze import purge_free_text_cloze

    bind = op.get_bind()
    with Session(bind) as session:
        purge_free_text_cloze(session)
        session.commit()


def downgrade() -> None:
    # Free-text cloze bits are not restored.
    pass
