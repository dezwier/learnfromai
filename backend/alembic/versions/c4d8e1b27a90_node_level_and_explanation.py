"""Add hierarchy level and a range explanation to each node.

Revision ID: c4d8e1b27a90
Revises: b7e2c4a91d03
Create Date: 2026-11-08 06:20:00.000000
"""

from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op

revision: str = "c4d8e1b27a90"
down_revision: Union[str, None] = "b7e2c4a91d03"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.add_column("concepts", sa.Column("level", sa.Integer(), nullable=False, server_default="0"))
    op.add_column("concepts", sa.Column("explanation", sa.Text(), nullable=False, server_default=""))
    op.execute(
        """
        WITH RECURSIVE depths AS (
            SELECT id, 0 AS level
            FROM concepts AS concept
            WHERE NOT EXISTS (
                SELECT 1
                FROM edges AS edge
                WHERE edge.to_concept_id = concept.id
                  AND edge.type = 'contains'
            )
            UNION ALL
            SELECT edge.to_concept_id, depths.level + 1
            FROM depths
            JOIN edges AS edge
              ON edge.from_concept_id = depths.id
             AND edge.type = 'contains'
            WHERE depths.level < 30
        )
        UPDATE concepts
        SET level = ranked.level
        FROM (
            SELECT id, MIN(level) AS level
            FROM depths
            GROUP BY id
        ) AS ranked
        WHERE concepts.id = ranked.id
        """
    )
    op.create_index("ix_concepts_level", "concepts", ["level"])


def downgrade() -> None:
    op.drop_index("ix_concepts_level", table_name="concepts")
    op.drop_column("concepts", "explanation")
    op.drop_column("concepts", "level")
