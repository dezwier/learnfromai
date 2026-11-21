"""Admin-only deletion of shared packs / quiz bits (+ related progress)."""

from __future__ import annotations

from uuid import UUID

from sqlalchemy import Integer, cast, delete
from sqlmodel import Session, col, select

from app.core.errors import AppError, not_found
from app.features.content.models import (
    CHECK_KINDS,
    DEFAULT_BAND,
    LEGACY_CHECK_KIND,
    LEGACY_EXAMPLE_KIND,
    RECIPE_VERSION,
    KnowledgeBit,
)
from app.features.knowledge_graph.node_models import KnowledgeNode
from app.features.reviews.models import UserPackReview
from app.features.user_events.models import UserTopicEvent

_PACK_EVENT_KINDS = frozenset(
    {"learn", LEGACY_EXAMPLE_KIND, "check1", "check2", "check3", LEGACY_CHECK_KIND}
)


def _normalize_check_kind(kind: str) -> str:
    raw = (kind or "").strip().lower()
    if raw == LEGACY_CHECK_KIND:
        return "check1"
    if raw not in CHECK_KINDS:
        raise AppError("VALIDATION_ERROR", "kind must be check1, check2, or check3", 422)
    return raw


def _pack_index_match(pack_index: int):
    return cast(UserTopicEvent.payload["pack_index"].astext, Integer) == int(pack_index)


def _require_node(session: Session, node_id: UUID) -> KnowledgeNode:
    node = session.get(KnowledgeNode, node_id)
    if node is None:
        raise not_found("Topic not found")
    return node


def _bits_for_pack(
    session: Session,
    node_id: UUID,
    pack_index: int,
    *,
    band: str,
    recipe_version: int,
) -> list[KnowledgeBit]:
    return list(
        session.exec(
            select(KnowledgeBit).where(
                KnowledgeBit.node_id == node_id,
                KnowledgeBit.pack_index == pack_index,
                KnowledgeBit.band == band,
                KnowledgeBit.recipe_version == recipe_version,
            )
        ).all()
    )


def _delete_pack_events(session: Session, *, node_id: UUID, pack_index: int) -> int:
    result = session.execute(
        delete(UserTopicEvent).where(
            UserTopicEvent.node_id == node_id,
            col(UserTopicEvent.kind).in_(list(_PACK_EVENT_KINDS)),
            _pack_index_match(pack_index),
        )
    )
    return int(result.rowcount or 0)


def _delete_check_events(
    session: Session, *, node_id: UUID, pack_index: int, kind: str
) -> int:
    kinds = [kind]
    if kind == "check1":
        kinds.append(LEGACY_CHECK_KIND)
    result = session.execute(
        delete(UserTopicEvent).where(
            UserTopicEvent.node_id == node_id,
            col(UserTopicEvent.kind).in_(kinds),
            _pack_index_match(pack_index),
        )
    )
    return int(result.rowcount or 0)


def _delete_pack_reviews(session: Session, *, node_id: UUID, pack_index: int) -> int:
    result = session.execute(
        delete(UserPackReview).where(
            UserPackReview.node_id == node_id,
            UserPackReview.pack_index == pack_index,
        )
    )
    return int(result.rowcount or 0)


def remaining_check_kinds(
    session: Session,
    node_id: UUID,
    pack_index: int,
    *,
    band: str = DEFAULT_BAND,
    recipe_version: int = RECIPE_VERSION,
) -> set[str]:
    """Normalized check kinds still present on the pack."""
    kinds: set[str] = set()
    for row in _bits_for_pack(
        session, node_id, pack_index, band=band, recipe_version=recipe_version
    ):
        if row.kind in CHECK_KINDS:
            kinds.add(row.kind)
        elif row.kind == LEGACY_CHECK_KIND:
            kinds.add("check1")
    return kinds


def delete_pack(
    session: Session,
    *,
    node_id: UUID,
    pack_index: int,
    band: str = DEFAULT_BAND,
    recipe_version: int = RECIPE_VERSION,
) -> dict:
    """Delete a pack, its bits, related events, and Leitner reviews for all users."""
    _require_node(session, node_id)
    if pack_index < 1:
        raise AppError("VALIDATION_ERROR", "pack_index must be >= 1", 422)
    bits = _bits_for_pack(
        session, node_id, pack_index, band=band, recipe_version=recipe_version
    )
    if not bits:
        raise not_found("Pack not found")
    bit_ids = [row.id for row in bits]
    session.execute(delete(KnowledgeBit).where(col(KnowledgeBit.id).in_(bit_ids)))
    events = _delete_pack_events(session, node_id=node_id, pack_index=pack_index)
    reviews = _delete_pack_reviews(session, node_id=node_id, pack_index=pack_index)
    session.flush()
    return {
        "deleted": "pack",
        "node_id": str(node_id),
        "pack_index": pack_index,
        "bits_deleted": len(bit_ids),
        "events_deleted": events,
        "reviews_deleted": reviews,
    }


def delete_check_bit(
    session: Session,
    *,
    node_id: UUID,
    pack_index: int,
    kind: str,
    band: str = DEFAULT_BAND,
    recipe_version: int = RECIPE_VERSION,
    confirm_last_pack: bool = False,
) -> dict:
    """Delete one quiz bit (+ its events). Last remaining quiz deletes the pack."""
    _require_node(session, node_id)
    if pack_index < 1:
        raise AppError("VALIDATION_ERROR", "pack_index must be >= 1", 422)
    check_kind = _normalize_check_kind(kind)
    remaining = remaining_check_kinds(
        session, node_id, pack_index, band=band, recipe_version=recipe_version
    )
    if check_kind not in remaining:
        raise not_found("Quiz not found on this pack")
    if len(remaining) <= 1:
        if not confirm_last_pack:
            raise AppError(
                "CONFIRM_PACK_DELETE",
                "This is the last quiz on the pack; deleting it removes the whole pack.",
                409,
                details={
                    "would_delete_pack": True,
                    "pack_index": pack_index,
                    "kind": check_kind,
                },
            )
        return delete_pack(
            session,
            node_id=node_id,
            pack_index=pack_index,
            band=band,
            recipe_version=recipe_version,
        )

    bit_kinds = [check_kind]
    if check_kind == "check1":
        bit_kinds.append(LEGACY_CHECK_KIND)
    bits = list(
        session.exec(
            select(KnowledgeBit).where(
                KnowledgeBit.node_id == node_id,
                KnowledgeBit.pack_index == pack_index,
                KnowledgeBit.band == band,
                KnowledgeBit.recipe_version == recipe_version,
                col(KnowledgeBit.kind).in_(bit_kinds),
            )
        ).all()
    )
    if not bits:
        raise not_found("Quiz not found on this pack")
    session.execute(
        delete(KnowledgeBit).where(col(KnowledgeBit.id).in_([row.id for row in bits]))
    )
    events = _delete_check_events(
        session, node_id=node_id, pack_index=pack_index, kind=check_kind
    )
    session.flush()
    return {
        "deleted": "quiz",
        "node_id": str(node_id),
        "pack_index": pack_index,
        "kind": check_kind,
        "bits_deleted": len(bits),
        "events_deleted": events,
        "reviews_deleted": 0,
        "remaining_checks": sorted(remaining - {check_kind}),
    }
