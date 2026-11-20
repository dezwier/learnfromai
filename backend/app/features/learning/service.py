"""Pick the next unlearned atomic pack (exploit seed / explore neighbors)."""

from __future__ import annotations

import random
from uuid import UUID

from sqlmodel import Session, col, select

from app.core.config import Settings, get_settings
from app.core.errors import not_found
from app.features.accounts.models import User
from app.features.content.service import (
    completed_pack_indexes,
    content_for_node,
    is_pack_complete,
)
from app.features.knowledge_graph.node_models import KnowledgeEdge, KnowledgeNode
from app.features.node_image.service import has_image, image_path_for, thumb_path_for
from app.features.ranking.affinity import score_user_tiles

_EPS = 1e-6


def _image_fields(node: KnowledgeNode) -> dict[str, str | None]:
    if not has_image(node):
        return {"image_url": None, "image_thumb_url": None}
    return {
        "image_url": image_path_for(node.id),
        "image_thumb_url": thumb_path_for(node.id),
    }


def _direct_neighbor_ids(session: Session, seed_id: UUID) -> set[UUID]:
    ids: set[UUID] = set()
    for edge in session.exec(select(KnowledgeEdge).where(KnowledgeEdge.from_id == seed_id)).all():
        ids.add(edge.to_id)
    return ids


def _eligible_packs(
    session: Session,
    *,
    user_id: UUID,
    node_id: UUID,
    exclude_pack_index: int | None = None,
) -> list[dict]:
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
    out.sort(key=lambda p: int(p["pack_index"]))
    return out


def _weighted_choice(candidates: list[tuple[UUID, float]], rng: random.Random) -> UUID:
    weights = [max(score, _EPS) for _, score in candidates]
    total = sum(weights)
    pick = rng.random() * total
    running = 0.0
    for (node_id, _), weight in zip(candidates, weights):
        running += weight
        if pick <= running:
            return node_id
    return candidates[-1][0]


def learning_next(
    session: Session,
    *,
    user: User,
    seed_node_id: UUID,
    exclude_node_id: UUID | None = None,
    exclude_pack_index: int | None = None,
    settings: Settings | None = None,
    rng: random.Random | None = None,
) -> dict:
    """Return the next pack to learn, or a generate hint for the seed.

    Optional exclude_* skips a pack still on-screen so the client can prefetch
    the following card before the user finishes the current quiz.
    """
    s = settings or get_settings()
    rng = rng or random.Random()
    seed = session.get(KnowledgeNode, seed_node_id)
    if seed is None:
        raise not_found("Topic not found")

    candidate_ids = {seed_node_id} | _direct_neighbor_ids(session, seed_node_id)
    nodes = {
        node.id: node
        for node in session.exec(
            select(KnowledgeNode).where(col(KnowledgeNode.id).in_(list(candidate_ids)))
        ).all()
    }
    scored = score_user_tiles(session, user_id=user.id, settings=s)
    affinity_by_id = {
        nid: float(row.get("affinity") or 0.0) for nid, row in scored.items() if nid in candidate_ids
    }

    eligible_by_node: dict[UUID, list[dict]] = {}
    for nid in candidate_ids:
        skip_pack = (
            exclude_pack_index
            if exclude_node_id is not None and nid == exclude_node_id
            else None
        )
        packs = _eligible_packs(
            session,
            user_id=user.id,
            node_id=nid,
            exclude_pack_index=skip_pack,
        )
        if packs:
            eligible_by_node[nid] = packs

    if not eligible_by_node:
        return {
            "status": "generate",
            "node_id": str(seed_node_id),
            "title": seed.name,
            **_image_fields(seed),
        }

    seed_has = seed_node_id in eligible_by_node
    exploit_p = float(s.learn_track_exploit_p)
    if seed_has and rng.random() < exploit_p:
        chosen_id = seed_node_id
    else:
        explore = [
            (nid, affinity_by_id.get(nid, _EPS)) for nid in eligible_by_node
        ]
        chosen_id = _weighted_choice(explore, rng)

    packs = eligible_by_node[chosen_id]
    pack = packs[0]
    node = nodes[chosen_id]
    # Avoid returning completed_packs noise; client only needs this pack.
    pack_payload = {
        "pack_index": pack["pack_index"],
        "incomplete": pack.get("incomplete", False),
        "title": pack.get("title"),
        "bits": pack.get("bits") or [],
    }
    return {
        "status": "ready",
        "node_id": str(chosen_id),
        "title": node.name,
        "pack_index": pack["pack_index"],
        "pack": pack_payload,
        "affinity": affinity_by_id.get(chosen_id, 0.0),
        "completed_packs": completed_pack_indexes(
            session, user_id=user.id, node_id=chosen_id
        ),
        **_image_fields(node),
    }
