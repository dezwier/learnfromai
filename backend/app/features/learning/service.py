"""Pick the next learning-track pack from the focus tile's perspective."""

from __future__ import annotations

import random
from uuid import UUID

from sqlmodel import Session, select

from app.core.config import get_settings
from app.core.errors import not_found
from app.features.accounts.models import User
from app.features.content.service import (
    completed_pack_indexes,
    content_for_node,
    is_pack_complete,
)
from app.features.knowledge_graph.node_models import KnowledgeEdge, KnowledgeNode
from app.features.node_image.pack_service import pack_image_fields


def _image_fields(
    session: Session,
    node: KnowledgeNode,
    pack_index: int | None = None,
) -> dict[str, str | None]:
    return pack_image_fields(session, node, pack_index)


def _neighbor_buckets(
    session: Session, focus_id: UUID
) -> tuple[list[UUID], list[UUID]]:
    """Children vs other direct neighbors (parent / sibling / acquaintance)."""
    children: list[UUID] = []
    others: list[UUID] = []
    seen: set[UUID] = set()
    for edge in session.exec(
        select(KnowledgeEdge).where(KnowledgeEdge.from_id == focus_id)
    ).all():
        if edge.to_id in seen:
            continue
        seen.add(edge.to_id)
        if edge.relation == "child":
            children.append(edge.to_id)
        else:
            others.append(edge.to_id)
    children.sort(key=lambda nid: nid.hex)
    others.sort(key=lambda nid: nid.hex)
    return children, others


def _eligible_packs(
    session: Session,
    *,
    user_id: UUID,
    node_id: UUID,
    exclude_pack_index: int | None = None,
) -> list[dict]:
    """Content-complete packs the user has not finished yet."""
    payload = content_for_node(session, node_id, user_id=user_id)
    completed = set(payload.get("completed_packs") or [])
    out: list[dict] = []
    for pack in payload.get("packs") or []:
        if not isinstance(pack, dict):
            continue
        pack_index = int(pack.get("pack_index") or 0)
        if pack_index < 1:
            continue
        if exclude_pack_index is not None and pack_index == exclude_pack_index:
            continue
        if pack.get("incomplete") is True:
            continue
        if not is_pack_complete(session, node_id, pack_index=pack_index):
            continue
        if pack_index in completed:
            continue
        out.append(pack)
    return out


def _learned_packs(
    session: Session,
    *,
    user_id: UUID,
    node_id: UUID,
    exclude_pack_index: int | None = None,
) -> list[dict]:
    """Content-complete packs the user already finished (replay)."""
    payload = content_for_node(session, node_id, user_id=user_id)
    completed = set(payload.get("completed_packs") or [])
    out: list[dict] = []
    for pack in payload.get("packs") or []:
        if not isinstance(pack, dict):
            continue
        pack_index = int(pack.get("pack_index") or 0)
        if pack_index < 1:
            continue
        if exclude_pack_index is not None and pack_index == exclude_pack_index:
            continue
        if pack.get("incomplete") is True:
            continue
        if not is_pack_complete(session, node_id, pack_index=pack_index):
            continue
        if pack_index not in completed:
            continue
        out.append(pack)
    return out


def _ready_payload(
    session: Session,
    *,
    user_id: UUID,
    node: KnowledgeNode,
    pack: dict,
) -> dict:
    pack_payload = {
        "pack_index": pack["pack_index"],
        "incomplete": pack.get("incomplete", False),
        "title": pack.get("title"),
        "bits": pack.get("bits") or [],
    }
    return {
        "status": "ready",
        "node_id": str(node.id),
        "title": node.name,
        "pack_index": pack["pack_index"],
        "pack": pack_payload,
        "affinity": 0.0,
        "completed_packs": completed_pack_indexes(
            session, user_id=user_id, node_id=node.id
        ),
        **_image_fields(session, node, pack["pack_index"]),
    }


def _generate_payload(session: Session, node: KnowledgeNode) -> dict:
    return {
        "status": "generate",
        "node_id": str(node.id),
        "title": node.name,
        **_image_fields(session, node, None),
    }


def _exclude_for(
    node_id: UUID,
    *,
    exclude_node_id: UUID | None,
    exclude_pack_index: int | None,
) -> int | None:
    if (
        exclude_node_id is not None
        and exclude_pack_index is not None
        and exclude_node_id == node_id
    ):
        return exclude_pack_index
    return None


def _pick_pack(
    packs: list[dict],
    rng: random.Random,
) -> dict:
    return packs[rng.randrange(len(packs))]


def _opening_pack(
    session: Session,
    *,
    user: User,
    focus: KnowledgeNode,
    rng: random.Random,
) -> dict:
    """First card: pack on the opening tile (unlearned preferred, else learned)."""
    unlearned = _eligible_packs(session, user_id=user.id, node_id=focus.id)
    if unlearned:
        return _ready_payload(
            session, user_id=user.id, node=focus, pack=_pick_pack(unlearned, rng)
        )
    learned = _learned_packs(session, user_id=user.id, node_id=focus.id)
    if learned:
        return _ready_payload(
            session, user_id=user.id, node=focus, pack=_pick_pack(learned, rng)
        )
    return _generate_payload(session, focus)


def _dice_tile(
    *,
    focus_id: UUID,
    children: list[UUID],
    others: list[UUID],
    rng: random.Random,
) -> UUID:
    """Weighted tile from the focus tile's perspective; empty buckets drop out."""
    settings = get_settings()
    buckets: list[tuple[float, list[UUID]]] = [
        (settings.learn_track_p_focus, [focus_id]),
    ]
    if children:
        buckets.append((settings.learn_track_p_child, children))
    if others:
        buckets.append((settings.learn_track_p_other, others))
    total = sum(weight for weight, _ in buckets)
    if total <= 0:
        return focus_id
    draw = rng.random() * total
    cursor = 0.0
    for weight, ids in buckets:
        cursor += weight
        if draw <= cursor:
            return ids[rng.randrange(len(ids))]
    return buckets[-1][1][rng.randrange(len(buckets[-1][1]))]


def _unlearned_on_tile(
    session: Session,
    *,
    user: User,
    focus: KnowledgeNode,
    tile_id: UUID,
    exclude_node_id: UUID | None,
    exclude_pack_index: int | None,
    rng: random.Random,
) -> dict | None:
    """Ready payload for an unlearned pack on [tile_id], or None."""
    skip = _exclude_for(
        tile_id,
        exclude_node_id=exclude_node_id,
        exclude_pack_index=exclude_pack_index,
    )
    unlearned = _eligible_packs(
        session, user_id=user.id, node_id=tile_id, exclude_pack_index=skip
    )
    if not unlearned:
        return None
    node = focus if tile_id == focus.id else session.get(KnowledgeNode, tile_id)
    if node is None:
        return None
    return _ready_payload(
        session, user_id=user.id, node=node, pack=_pick_pack(unlearned, rng)
    )


def _first_unlearned_in_neighborhood(
    session: Session,
    *,
    user: User,
    focus: KnowledgeNode,
    exclude_node_id: UUID | None,
    exclude_pack_index: int | None,
    rng: random.Random,
) -> dict | None:
    """First unlearned pack: focus → children → siblings/parents/acquaintance."""
    children, others = _neighbor_buckets(session, focus.id)
    for tile_id in [focus.id, *children, *others]:
        ready = _unlearned_on_tile(
            session,
            user=user,
            focus=focus,
            tile_id=tile_id,
            exclude_node_id=exclude_node_id,
            exclude_pack_index=exclude_pack_index,
            rng=rng,
        )
        if ready is not None:
            return ready
    return None


def _pack_for_tile(
    session: Session,
    *,
    user: User,
    focus: KnowledgeNode,
    tile_id: UUID,
    exclude_node_id: UUID | None,
    exclude_pack_index: int | None,
    rng: random.Random,
) -> dict:
    """Unlearned pack on [tile_id], or generate for that tile (prefetch dice)."""
    ready = _unlearned_on_tile(
        session,
        user=user,
        focus=focus,
        tile_id=tile_id,
        exclude_node_id=exclude_node_id,
        exclude_pack_index=exclude_pack_index,
        rng=rng,
    )
    if ready is not None:
        return ready
    node = focus if tile_id == focus.id else session.get(KnowledgeNode, tile_id)
    if node is None:
        return _generate_payload(session, focus)
    return _generate_payload(session, node)


def _advance_picked(
    session: Session,
    *,
    user: User,
    focus: KnowledgeNode,
    picked_node_id: UUID,
    exclude_node_id: UUID | None,
    exclude_pack_index: int | None,
    rng: random.Random,
) -> dict:
    """On Next: dice tile if ready, else neighborhood unlearned, else generate(picked)."""
    ready = _unlearned_on_tile(
        session,
        user=user,
        focus=focus,
        tile_id=picked_node_id,
        exclude_node_id=exclude_node_id,
        exclude_pack_index=exclude_pack_index,
        rng=rng,
    )
    if ready is not None:
        return ready
    fallback = _first_unlearned_in_neighborhood(
        session,
        user=user,
        focus=focus,
        exclude_node_id=exclude_node_id,
        exclude_pack_index=exclude_pack_index,
        rng=rng,
    )
    if fallback is not None:
        return fallback
    node = (
        focus
        if picked_node_id == focus.id
        else session.get(KnowledgeNode, picked_node_id)
    )
    if node is None:
        return _generate_payload(session, focus)
    return _generate_payload(session, node)


def _continue_pack(
    session: Session,
    *,
    user: User,
    focus: KnowledgeNode,
    exclude_node_id: UUID | None,
    exclude_pack_index: int | None,
    rng: random.Random,
) -> dict:
    """Prefetch: dice a tile, then unlearned pack or generate for that tile only."""
    children, others = _neighbor_buckets(session, focus.id)
    tile_id = _dice_tile(
        focus_id=focus.id, children=children, others=others, rng=rng
    )
    return _pack_for_tile(
        session,
        user=user,
        focus=focus,
        tile_id=tile_id,
        exclude_node_id=exclude_node_id,
        exclude_pack_index=exclude_pack_index,
        rng=rng,
    )


def learning_next(
    session: Session,
    *,
    user: User,
    seed_node_id: UUID,
    exclude_node_id: UUID | None = None,
    exclude_pack_index: int | None = None,
    opening: bool = False,
    picked_node_id: UUID | None = None,
    rng: random.Random | None = None,
) -> dict:
    """Return the next pack to learn, or a generate hint for a chosen tile.

    Always interpreted from the track's opening focus (`seed_node_id`):
    - `opening=True`: pack on the focus (prefer unlearned, else learned, else generate).
    - `picked_node_id`: advance after a dice prefetch — prefer that tile's unlearned,
      else any unlearned in the neighborhood (focus → children → others), else
      `generate` for the picked tile (client waits only then).
    - otherwise: weighted dice (focus / children / other neighbors), then an
      unlearned pack on that tile or `generate` for it (prefetch hint; no fallback).
    Optional exclude_* skips the on-screen pack when prefetching / advancing.
    """
    seed = session.get(KnowledgeNode, seed_node_id)
    if seed is None:
        raise not_found("Topic not found")

    picker = rng if rng is not None else random.Random()
    if opening:
        return _opening_pack(session, user=user, focus=seed, rng=picker)
    if picked_node_id is not None:
        return _advance_picked(
            session,
            user=user,
            focus=seed,
            picked_node_id=picked_node_id,
            exclude_node_id=exclude_node_id,
            exclude_pack_index=exclude_pack_index,
            rng=picker,
        )
    return _continue_pack(
        session,
        user=user,
        focus=seed,
        exclude_node_id=exclude_node_id,
        exclude_pack_index=exclude_pack_index,
        rng=picker,
    )
