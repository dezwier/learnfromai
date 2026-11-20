"""Pick the next unlearned atomic pack (focus first, then neighbors)."""

from __future__ import annotations

from uuid import UUID

from sqlmodel import Session, col, select

from app.core.errors import not_found
from app.features.accounts.models import User
from app.features.content.service import (
    completed_pack_indexes,
    content_for_node,
    is_pack_complete,
)
from app.features.knowledge_graph.node_models import KnowledgeEdge, KnowledgeNode
from app.features.node_image.service import has_image, image_path_for, thumb_path_for


def _image_fields(node: KnowledgeNode) -> dict[str, str | None]:
    if not has_image(node):
        return {"image_url": None, "image_thumb_url": None}
    return {
        "image_url": image_path_for(node.id),
        "image_thumb_url": thumb_path_for(node.id),
    }


def _direct_neighbor_ids(session: Session, seed_id: UUID) -> list[UUID]:
    """Stable neighbor order (by id) for deterministic picks."""
    ids: set[UUID] = set()
    for edge in session.exec(select(KnowledgeEdge).where(KnowledgeEdge.from_id == seed_id)).all():
        ids.add(edge.to_id)
    return sorted(ids, key=lambda nid: nid.hex)


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
        **_image_fields(node),
    }


def learning_next(
    session: Session,
    *,
    user: User,
    seed_node_id: UUID,
    exclude_node_id: UUID | None = None,
    exclude_pack_index: int | None = None,
) -> dict:
    """Return the next pack to learn, or a generate hint for the seed.

    Fast path: unlearned pack on the focus first; only then scan neighbors.
    Optional exclude_* skips a pack still on-screen so the client can prefetch.
    """
    seed = session.get(KnowledgeNode, seed_node_id)
    if seed is None:
        raise not_found("Topic not found")

    seed_exclude = (
        exclude_pack_index
        if exclude_node_id is not None and exclude_node_id == seed_node_id
        else None
    )
    seed_packs = _eligible_packs(
        session,
        user_id=user.id,
        node_id=seed_node_id,
        exclude_pack_index=seed_exclude,
    )
    if seed_packs:
        return _ready_payload(session, user_id=user.id, node=seed, pack=seed_packs[0])

    neighbor_ids = _direct_neighbor_ids(session, seed_node_id)
    if neighbor_ids:
        neighbors = {
            node.id: node
            for node in session.exec(
                select(KnowledgeNode).where(col(KnowledgeNode.id).in_(neighbor_ids))
            ).all()
        }
        for nid in neighbor_ids:
            node = neighbors.get(nid)
            if node is None:
                continue
            skip = (
                exclude_pack_index
                if exclude_node_id is not None and exclude_node_id == nid
                else None
            )
            packs = _eligible_packs(
                session,
                user_id=user.id,
                node_id=nid,
                exclude_pack_index=skip,
            )
            if packs:
                return _ready_payload(session, user_id=user.id, node=node, pack=packs[0])

    return {
        "status": "generate",
        "node_id": str(seed_node_id),
        "title": seed.name,
        **_image_fields(seed),
    }
