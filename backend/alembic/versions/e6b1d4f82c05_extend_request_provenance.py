"""Record which extend added each node and edge.

Revision ID: e6b1d4f82c05
Revises: c4d8e1b27a90
Create Date: 2026-11-08 10:57:00.000000
"""

from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op

revision: str = "e6b1d4f82c05"
down_revision: Union[str, None] = "c4d8e1b27a90"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None

_BACKFILL = """
UPDATE {table} AS row
SET extend_request_id = (
    SELECT request.id
    FROM extend_requests AS request
    WHERE request.graph_id = row.{graph_column}
      AND request.created_at <= row.created_at
      AND (request.finished_at IS NULL OR request.finished_at >= row.created_at)
    ORDER BY request.finished_at ASC NULLS LAST, request.created_at DESC
    LIMIT 1
)
WHERE row.extend_request_id IS NULL
"""


def upgrade() -> None:
    op.add_column("concepts", sa.Column("extend_request_id", sa.Uuid(), nullable=True))
    op.add_column("edges", sa.Column("extend_request_id", sa.Uuid(), nullable=True))
    op.create_index("ix_concepts_extend_request_id", "concepts", ["extend_request_id"])
    op.create_index("ix_edges_extend_request_id", "edges", ["extend_request_id"])
    op.create_foreign_key("fk_concepts_extend_request", "concepts", "extend_requests", ["extend_request_id"], ["id"])
    op.create_foreign_key("fk_edges_extend_request", "edges", "extend_requests", ["extend_request_id"], ["id"])
    op.execute(_BACKFILL.format(table="concepts", graph_column="origin_graph_id"))
    op.execute(_BACKFILL.format(table="edges", graph_column="graph_id"))


def downgrade() -> None:
    op.drop_constraint("fk_edges_extend_request", "edges", type_="foreignkey")
    op.drop_constraint("fk_concepts_extend_request", "concepts", type_="foreignkey")
    op.drop_index("ix_edges_extend_request_id", table_name="edges")
    op.drop_index("ix_concepts_extend_request_id", table_name="concepts")
    op.drop_column("edges", "extend_request_id")
    op.drop_column("concepts", "extend_request_id")
