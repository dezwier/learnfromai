"""Delete legacy free-text cloze bits; drop packs left with no playable quiz."""

from __future__ import annotations

from uuid import UUID

from sqlalchemy import Integer, cast, delete
from sqlmodel import Session, col, select

from app.features.content.models import (
    CHECK_KINDS,
    DEFAULT_BAND,
    LEGACY_CHECK_KIND,
    LEGACY_EXAMPLE_KIND,
    RECIPE_VERSION,
    KnowledgeBit,
)
from app.features.content.service import is_free_text_cloze_body, is_playable_check_body
from app.features.reviews.models import UserPackReview
from app.features.user_events.models import UserTopicEvent

_PACK_EVENT_KINDS = frozenset(
    {"learn", LEGACY_EXAMPLE_KIND, "check1", "check2", "check3", LEGACY_CHECK_KIND}
)


def _pack_index_match(pack_index: int):
    return cast(UserTopicEvent.payload["pack_index"].astext, Integer) == int(pack_index)


def _delete_pack(
    session: Session,
    *,
    node_id: UUID,
    pack_index: int,
    band: str,
    recipe_version: int,
) -> dict[str, int]:
    bits = list(
        session.exec(
            select(KnowledgeBit).where(
                KnowledgeBit.node_id == node_id,
                KnowledgeBit.pack_index == pack_index,
                KnowledgeBit.band == band,
                KnowledgeBit.recipe_version == recipe_version,
            )
        ).all()
    )
    bit_count = len(bits)
    if bits:
        session.execute(
            delete(KnowledgeBit).where(col(KnowledgeBit.id).in_([row.id for row in bits]))
        )
    events = session.execute(
        delete(UserTopicEvent).where(
            UserTopicEvent.node_id == node_id,
            col(UserTopicEvent.kind).in_(list(_PACK_EVENT_KINDS)),
            _pack_index_match(pack_index),
        )
    )
    reviews = session.execute(
        delete(UserPackReview).where(
            UserPackReview.node_id == node_id,
            UserPackReview.pack_index == pack_index,
        )
    )
    return {
        "bits": bit_count,
        "events": int(events.rowcount or 0),
        "reviews": int(reviews.rowcount or 0),
    }


def purge_free_text_cloze(
    session: Session,
    *,
    band: str = DEFAULT_BAND,
    recipe_version: int = RECIPE_VERSION,
) -> dict[str, int]:
    """Remove open-answer cloze quizzes; delete packs with no playable check left."""
    rows = list(
        session.exec(
            select(KnowledgeBit).where(
                KnowledgeBit.band == band,
                KnowledgeBit.recipe_version == recipe_version,
                col(KnowledgeBit.kind).in_(list(CHECK_KINDS) + [LEGACY_CHECK_KIND]),
            )
        ).all()
    )
    deleted_bits = 0
    touched: set[tuple[UUID, int]] = set()
    for row in rows:
        if not is_free_text_cloze_body(row.body):
            continue
        session.delete(row)
        deleted_bits += 1
        touched.add((row.node_id, row.pack_index))
    session.flush()

    packs_deleted = 0
    cascade_bits = 0
    cascade_events = 0
    cascade_reviews = 0
    for node_id, pack_index in sorted(touched, key=lambda item: (item[0].hex, item[1])):
        remaining = list(
            session.exec(
                select(KnowledgeBit).where(
                    KnowledgeBit.node_id == node_id,
                    KnowledgeBit.pack_index == pack_index,
                    KnowledgeBit.band == band,
                    KnowledgeBit.recipe_version == recipe_version,
                )
            ).all()
        )
        playable = [
            row
            for row in remaining
            if (row.kind in CHECK_KINDS or row.kind == LEGACY_CHECK_KIND)
            and is_playable_check_body(row.body)
        ]
        if playable:
            continue
        stats = _delete_pack(
            session,
            node_id=node_id,
            pack_index=pack_index,
            band=band,
            recipe_version=recipe_version,
        )
        packs_deleted += 1
        cascade_bits += stats["bits"]
        cascade_events += stats["events"]
        cascade_reviews += stats["reviews"]
    session.flush()
    return {
        "cloze_bits_deleted": deleted_bits,
        "packs_deleted": packs_deleted,
        "pack_bits_deleted": cascade_bits,
        "events_deleted": cascade_events,
        "reviews_deleted": cascade_reviews,
    }
