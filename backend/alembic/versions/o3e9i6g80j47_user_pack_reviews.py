"""Add user_pack_reviews for Leitner testing track.

Revision ID: o3e9i6g80j47
Revises: n2d8h5f79i36
Create Date: 2026-11-20 21:00:00.000000
"""

from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op

revision: str = "o3e9i6g80j47"
down_revision: Union[str, None] = "n2d8h5f79i36"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.create_table(
        "user_pack_reviews",
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column("user_id", sa.Uuid(), nullable=False),
        sa.Column("node_id", sa.Uuid(), nullable=False),
        sa.Column("pack_index", sa.Integer(), nullable=False),
        sa.Column("leitner_bin", sa.Integer(), nullable=False),
        sa.Column("last_review_time", sa.DateTime(timezone=True), nullable=True),
        sa.Column("next_review_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("graduated_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.ForeignKeyConstraint(["node_id"], ["knowledge_nodes.id"]),
        sa.ForeignKeyConstraint(["user_id"], ["users.id"]),
        sa.PrimaryKeyConstraint("id"),
        sa.UniqueConstraint(
            "user_id",
            "node_id",
            "pack_index",
            name="uq_user_pack_reviews_user_node_pack",
        ),
    )
    op.create_index("ix_user_pack_reviews_user_id", "user_pack_reviews", ["user_id"])
    op.create_index("ix_user_pack_reviews_node_id", "user_pack_reviews", ["node_id"])
    op.create_index(
        "ix_user_pack_reviews_next_review_at", "user_pack_reviews", ["next_review_at"]
    )

    # Backfill: packs that already have learn + any check → bin 1, due now.
    op.execute(
        sa.text(
            """
            WITH pack_kinds AS (
                SELECT
                    e.user_id,
                    e.node_id,
                    COALESCE(
                        NULLIF((e.payload->>'pack_index')::int, 0),
                        1
                    ) AS pack_index,
                    CASE
                        WHEN e.kind = 'check' THEN 'check1'
                        ELSE e.kind
                    END AS kind
                FROM user_topic_events e
                WHERE e.kind IN ('learn', 'example', 'check', 'check1', 'check2', 'check3')
            ),
            completed AS (
                SELECT
                    user_id,
                    node_id,
                    pack_index
                FROM pack_kinds
                WHERE kind IN ('learn', 'check1', 'check2', 'check3')
                GROUP BY user_id, node_id, pack_index
                HAVING
                    bool_or(kind = 'learn')
                    AND bool_or(kind IN ('check1', 'check2', 'check3'))
            )
            INSERT INTO user_pack_reviews (
                id, user_id, node_id, pack_index, leitner_bin,
                last_review_time, next_review_at, graduated_at, created_at
            )
            SELECT
                gen_random_uuid(),
                c.user_id,
                c.node_id,
                c.pack_index,
                1,
                NOW(),
                NOW(),
                NULL,
                NOW()
            FROM completed c
            """
        )
    )


def downgrade() -> None:
    op.drop_index("ix_user_pack_reviews_next_review_at", table_name="user_pack_reviews")
    op.drop_index("ix_user_pack_reviews_node_id", table_name="user_pack_reviews")
    op.drop_index("ix_user_pack_reviews_user_id", table_name="user_pack_reviews")
    op.drop_table("user_pack_reviews")
