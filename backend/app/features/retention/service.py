from __future__ import annotations

from uuid import UUID

from sqlmodel import Session, select

from app.core.time import utcnow
from app.features.retention.fsrs_adapter import (
    due_from_state,
    new_card_state,
    rating_from_score,
    review_state,
)
from app.features.retention.models import ReviewEvent, ReviewItem


def schedule_review(
    session: Session,
    *,
    user_id: UUID,
    concept_id: UUID,
    objective_id: UUID,
    objective_revision_id: UUID,
    activity_id: UUID | None,
    score: float,
    rating_override: str | None,
    attempt_id: UUID | None,
) -> ReviewItem:
    item = session.exec(
        select(ReviewItem).where(
            ReviewItem.user_id == user_id,
            ReviewItem.objective_id == objective_id,
            ReviewItem.status == "active",
        )
    ).first()
    now = utcnow()
    if item is None:
        item = ReviewItem(
            user_id=user_id,
            concept_id=concept_id,
            objective_id=objective_id,
            objective_revision_id=objective_revision_id,
            activity_template_id=activity_id,
            scheduler_version="fsrs-6.3.2",
            fsrs_state=new_card_state(now),
            due_at=now,
            status="active",
        )
        session.add(item)
        session.flush()
    rating = rating_from_score(score, rating_override)
    before = dict(item.fsrs_state)
    after, _event = review_state(before, rating, now)
    item.fsrs_state = after
    item.due_at = due_from_state(after)
    item.objective_revision_id = objective_revision_id
    if activity_id and item.activity_template_id is None:
        item.activity_template_id = activity_id
    session.add(
        ReviewEvent(
            review_item_id=item.id,
            attempt_id=attempt_id,
            rating=rating,
            scheduler_version="fsrs-6.3.2",
            before_state=before,
            after_state=after,
            rating_overridden=rating_override is not None,
        )
    )
    session.flush()
    return item


def due_items(session: Session, user_id: UUID, limit: int = 20) -> list[ReviewItem]:
    now = utcnow()
    rows = session.exec(
        select(ReviewItem)
        .where(ReviewItem.user_id == user_id, ReviewItem.status == "active", ReviewItem.due_at <= now)
        .order_by(ReviewItem.due_at)
        .limit(limit)
    ).all()
    return list(rows)


def retire_item(session: Session, item: ReviewItem) -> None:
    item.status = "retired"
    session.add(item)
    session.flush()
