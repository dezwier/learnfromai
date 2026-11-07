"""prospective mapping targets

Revision ID: ffe63ea80d8c
Revises: da61421d734a
Create Date: 2026-11-07 16:39:40.572740
"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa
import sqlmodel


revision: str = 'ffe63ea80d8c'
down_revision: Union[str, None] = 'da61421d734a'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.drop_constraint(op.f('concept_mappings_target_concept_id_fkey'), 'concept_mappings', type_='foreignkey')
    op.drop_constraint(op.f('objective_mappings_target_objective_id_fkey'), 'objective_mappings', type_='foreignkey')


def downgrade() -> None:
    op.create_foreign_key(op.f('objective_mappings_target_objective_id_fkey'), 'objective_mappings', 'learning_objectives', ['target_objective_id'], ['id'])
    op.create_foreign_key(op.f('concept_mappings_target_concept_id_fkey'), 'concept_mappings', 'concepts', ['target_concept_id'], ['id'])
