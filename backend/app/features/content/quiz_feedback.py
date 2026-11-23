"""Thumbs up/down feedback on shared quiz bits."""

from __future__ import annotations

from uuid import UUID

from sqlmodel import Session, select

from app.core.errors import AppError, not_found
from app.core.time import utcnow
from app.features.accounts.models import User
from app.features.content.models import CHECK_KINDS, LEGACY_CHECK_KIND, KnowledgeBit, QuizBitFeedback

_VALID_RATINGS = frozenset({1, -1})


def upsert_quiz_feedback(
    session: Session,
    *,
    user: User,
    bit_id: UUID,
    rating: int,
) -> dict:
    """Store or update this user's thumbs rating on a quiz bit."""
    if rating not in _VALID_RATINGS:
        raise AppError("VALIDATION_ERROR", "rating must be 1 or -1", 422)
    bit = session.get(KnowledgeBit, bit_id)
    if bit is None:
        raise not_found("Quiz not found")
    kind = "check1" if bit.kind == LEGACY_CHECK_KIND else bit.kind
    if kind not in CHECK_KINDS:
        raise AppError("VALIDATION_ERROR", "Feedback is only allowed on quiz bits", 422)

    row = session.exec(
        select(QuizBitFeedback).where(
            QuizBitFeedback.user_id == user.id,
            QuizBitFeedback.bit_id == bit_id,
        )
    ).first()
    now = utcnow()
    if row is None:
        row = QuizBitFeedback(
            user_id=user.id,
            bit_id=bit_id,
            rating=int(rating),
            created_at=now,
            updated_at=now,
        )
        session.add(row)
    else:
        row.rating = int(rating)
        row.updated_at = now
        session.add(row)
    session.flush()
    return {
        "bit_id": str(bit_id),
        "rating": int(row.rating),
        "kind": kind,
        "pack_index": int(bit.pack_index),
        "node_id": str(bit.node_id),
    }
