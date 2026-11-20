"""Leitner review APIs: enroll, distribution, due queue, submit."""

from __future__ import annotations

from datetime import datetime
from typing import Any
from uuid import UUID

from sqlalchemy import and_, case, func, or_
from sqlmodel import Session, col, select

from app.core.errors import AppError, not_found
from app.core.time import utcnow
from app.features.accounts.models import User
from app.features.content.models import (
    CHECK_KINDS,
    CONTENT_KINDS,
    DEFAULT_BAND,
    LEGACY_CHECK_KIND,
    RECIPE_VERSION,
    KnowledgeBit,
    pack_atomically_complete,
)
from app.features.content.service import content_for_node
from app.features.knowledge_graph.node_models import KnowledgeNode
from app.features.node_image.service import has_image, image_path_for, thumb_path_for
from app.features.reviews.models import (
    GRADUATION_BIN,
    LEITNER_BIN_8_HOURS,
    LEITNER_INTERVALS_HOURS,
    UserPackReview,
)
from app.features.reviews.srs import apply_review_result, enroll_first_learn, interval_hours_for_bin
from app.features.user_events.models import UserTopicEvent
from app.features.user_events.service import record_events

MAX_DUE_LIMIT = 20
DEFAULT_DUE_LIMIT = 10


def _image_fields(node: KnowledgeNode) -> dict[str, str | None]:
    if not has_image(node):
        return {"image_url": None, "image_thumb_url": None}
    return {
        "image_url": image_path_for(node.id),
        "image_thumb_url": thumb_path_for(node.id),
    }


def _pack_kinds_from_events(
    session: Session,
    *,
    user_id: UUID,
    node_id: UUID,
    pack_index: int,
) -> set[str]:
    rows = list(
        session.exec(
            select(UserTopicEvent).where(
                UserTopicEvent.user_id == user_id,
                UserTopicEvent.node_id == node_id,
                col(UserTopicEvent.kind).in_(list(CONTENT_KINDS) + [LEGACY_CHECK_KIND]),
            )
        ).all()
    )
    kinds: set[str] = set()
    for row in rows:
        payload = row.payload if isinstance(row.payload, dict) else {}
        try:
            event_pack = int(payload.get("pack_index") or 1)
        except (TypeError, ValueError):
            event_pack = 1
        if event_pack != pack_index:
            continue
        kind = "check1" if row.kind == LEGACY_CHECK_KIND else row.kind
        if kind in CONTENT_KINDS:
            kinds.add(kind)
    return kinds


def ensure_enrolled_if_complete(
    session: Session,
    *,
    user_id: UUID,
    node_id: UUID,
    pack_index: int,
    at: datetime | None = None,
) -> UserPackReview | None:
    """Enroll bin 1 when the pack is atomically complete and has no review row."""
    if pack_index < 1:
        return None
    existing = session.exec(
        select(UserPackReview).where(
            UserPackReview.user_id == user_id,
            UserPackReview.node_id == node_id,
            UserPackReview.pack_index == pack_index,
        )
    ).first()
    if existing is not None:
        return existing

    kinds = _pack_kinds_from_events(
        session, user_id=user_id, node_id=node_id, pack_index=pack_index
    )
    if not pack_atomically_complete(kinds):
        return None

    now = at or utcnow()
    row = UserPackReview(
        user_id=user_id,
        node_id=node_id,
        pack_index=pack_index,
    )
    enroll_first_learn(row, at=now)
    session.add(row)
    return row


def enroll_from_events(
    session: Session,
    *,
    user: User,
    events: list[UserTopicEvent],
) -> None:
    """After recording learn/check events, enroll any newly completed packs."""
    seen: set[tuple[UUID, int]] = set()
    for event in events:
        if event.kind not in CONTENT_KINDS and event.kind != LEGACY_CHECK_KIND:
            continue
        payload = event.payload if isinstance(event.payload, dict) else {}
        try:
            pack_index = int(payload.get("pack_index") or 1)
        except (TypeError, ValueError):
            pack_index = 1
        key = (event.node_id, pack_index)
        if key in seen:
            continue
        seen.add(key)
        ensure_enrolled_if_complete(
            session,
            user_id=user.id,
            node_id=event.node_id,
            pack_index=pack_index,
            at=event.occurred_at,
        )


def distribution_for_user(session: Session, *, user: User) -> dict:
    """Per-bin counts plus due totals for the testing-track hub."""
    now = utcnow()
    rows = list(
        session.exec(
            select(
                UserPackReview.leitner_bin,
                func.count(UserPackReview.id).label("count"),
                func.sum(
                    case(
                        (
                            and_(
                                UserPackReview.next_review_at.is_not(None),
                                UserPackReview.next_review_at < now,
                            ),
                            1,
                        ),
                        else_=0,
                    )
                ).label("count_due"),
                func.sum(
                    case(
                        (
                            or_(
                                UserPackReview.next_review_at.is_(None),
                                UserPackReview.next_review_at >= now,
                            ),
                            1,
                        ),
                        else_=0,
                    )
                ).label("count_not_due"),
            )
            .where(UserPackReview.user_id == user.id)
            .where(UserPackReview.leitner_bin >= 1)
            .group_by(UserPackReview.leitner_bin)
            .order_by(UserPackReview.leitner_bin)
        ).all()
    )

    by_bin: dict[int, dict[str, int]] = {}
    max_bin = GRADUATION_BIN
    due_count = 0
    for bin_number, count, count_due, count_not_due in rows:
        bin_i = int(bin_number or 0)
        if bin_i < 1:
            continue
        due_i = int(count_due or 0)
        by_bin[bin_i] = {
            "bin": bin_i,
            "count": int(count or 0),
            "count_due": due_i,
            "count_not_due": int(count_not_due or 0),
        }
        due_count += due_i
        if bin_i > max_bin:
            max_bin = bin_i

    distribution = [
        by_bin.get(
            bin_i,
            {"bin": bin_i, "count": 0, "count_due": 0, "count_not_due": 0},
        )
        for bin_i in range(1, max_bin + 1)
    ]

    first_next = session.exec(
        select(func.min(UserPackReview.next_review_at)).where(
            UserPackReview.user_id == user.id,
            UserPackReview.next_review_at.is_not(None),
            UserPackReview.next_review_at >= now,
        )
    ).one()

    return {
        "graduation_bin": GRADUATION_BIN,
        "intervals_hours": list(LEITNER_INTERVALS_HOURS),
        "bin_8_plus_hours": LEITNER_BIN_8_HOURS,
        "due_count": due_count,
        "first_next_review_at": first_next.isoformat() if first_next else None,
        "distribution": distribution,
    }


def due_reviews(
    session: Session,
    *,
    user: User,
    limit: int = DEFAULT_DUE_LIMIT,
) -> dict:
    """Return due packs with topic + pack bits for a review session."""
    capped = max(1, min(int(limit), MAX_DUE_LIMIT))
    now = utcnow()
    rows = list(
        session.exec(
            select(UserPackReview)
            .where(
                UserPackReview.user_id == user.id,
                UserPackReview.next_review_at.is_not(None),
                UserPackReview.next_review_at < now,
            )
            .order_by(UserPackReview.next_review_at, UserPackReview.created_at)
            .limit(capped)
        ).all()
    )
    if not rows:
        return {"items": [], "due_count": 0}

    node_ids = {row.node_id for row in rows}
    nodes = {
        node.id: node
        for node in session.exec(
            select(KnowledgeNode).where(col(KnowledgeNode.id).in_(list(node_ids)))
        ).all()
    }

    items: list[dict] = []
    for row in rows:
        node = nodes.get(row.node_id)
        if node is None:
            continue
        content = content_for_node(session, row.node_id, user_id=user.id)
        pack = next(
            (
                p
                for p in (content.get("packs") or [])
                if int(p.get("pack_index") or 0) == row.pack_index
            ),
            None,
        )
        if pack is None:
            continue
        items.append(
            {
                "node_id": str(node.id),
                "title": node.name,
                "pack_index": row.pack_index,
                "leitner_bin": row.leitner_bin,
                "next_review_at": (
                    row.next_review_at.isoformat() if row.next_review_at else None
                ),
                "pack": {
                    "pack_index": pack["pack_index"],
                    "incomplete": pack.get("incomplete", False),
                    "title": pack.get("title"),
                    "bits": pack.get("bits") or [],
                },
                **_image_fields(node),
            }
        )

    due_count = session.exec(
        select(func.count())
        .select_from(UserPackReview)
        .where(
            UserPackReview.user_id == user.id,
            UserPackReview.next_review_at.is_not(None),
            UserPackReview.next_review_at < now,
        )
    ).one()

    return {"items": items, "due_count": int(due_count or 0)}


def submit_review(
    session: Session,
    *,
    user: User,
    node_id: UUID,
    pack_index: int,
    correct: bool,
    check_kind: str,
    answer_fields: dict[str, Any],
) -> dict:
    """Grade a testing-track answer: log event + move Leitner bin."""
    if pack_index < 1:
        raise AppError("INVALID_REVIEW", "pack_index must be >= 1", 400)
    kind = check_kind.strip()
    if kind not in CHECK_KINDS:
        raise AppError(
            "INVALID_REVIEW",
            "check_kind must be check1, check2, or check3",
            400,
            {"allowed": list(CHECK_KINDS)},
        )
    node = session.get(KnowledgeNode, node_id)
    if node is None:
        raise not_found("Topic not found")

    bit = session.exec(
        select(KnowledgeBit).where(
            KnowledgeBit.node_id == node_id,
            KnowledgeBit.pack_index == pack_index,
            KnowledgeBit.kind == kind,
            KnowledgeBit.band == DEFAULT_BAND,
            KnowledgeBit.recipe_version == RECIPE_VERSION,
        )
    ).first()
    if bit is None and kind == "check1":
        bit = session.exec(
            select(KnowledgeBit).where(
                KnowledgeBit.node_id == node_id,
                KnowledgeBit.pack_index == pack_index,
                KnowledgeBit.kind == LEGACY_CHECK_KIND,
                KnowledgeBit.band == DEFAULT_BAND,
                KnowledgeBit.recipe_version == RECIPE_VERSION,
            )
        ).first()
    if bit is None:
        raise AppError("INVALID_REVIEW", "Check bit not found for pack", 404)

    payload: dict[str, Any] = {"pack_index": pack_index, "correct": correct, **answer_fields}
    recorded = record_events(
        session,
        user=user,
        items=[{"node_id": str(node_id), "kind": kind, "payload": payload}],
    )
    # record_events already enrolls via enroll_from_events when wired; ensure here too.
    enroll_from_events(session, user=user, events=recorded)

    row = session.exec(
        select(UserPackReview).where(
            UserPackReview.user_id == user.id,
            UserPackReview.node_id == node_id,
            UserPackReview.pack_index == pack_index,
        )
    ).first()
    if row is None:
        row = ensure_enrolled_if_complete(
            session,
            user_id=user.id,
            node_id=node_id,
            pack_index=pack_index,
        )
    if row is None:
        raise AppError(
            "INVALID_REVIEW",
            "Pack is not in the testing track yet (learn + check required)",
            400,
        )

    now = utcnow()
    updated = apply_review_result(row, correct=correct, at=now)
    session.add(row)

    return {
        "node_id": str(node_id),
        "pack_index": pack_index,
        "leitner_bin": row.leitner_bin,
        "next_review_at": row.next_review_at.isoformat() if row.next_review_at else None,
        "graduated": row.graduated_at is not None,
        "updated": updated,
        "interval_hours": interval_hours_for_bin(row.leitner_bin),
    }
