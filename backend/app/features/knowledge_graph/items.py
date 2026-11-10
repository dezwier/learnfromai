"""One shared Wikidata class graph.

Items and parent→child edges are stored once. A later topic reuses whatever
is already complete and still inside the cache window, and asks Wikidata only
for directions that are missing or stale.
"""

from __future__ import annotations

from collections import deque
from dataclasses import dataclass
from datetime import datetime, timedelta
from uuid import UUID

from sqlmodel import Session, col, func, select

from app.core.config import get_settings
from app.core.errors import AppError, not_found
from app.core.time import utcnow
from app.features.knowledge_graph.identity import same_topic
from app.features.knowledge_graph.item_models import (
    KnowledgeGraphRequest,
    KnowledgeGraphRequestNode,
    KnowledgeItem,
    KnowledgeItemEdge,
)
from app.features.knowledge_graph.wikidata import (
    DOMAIN_ROOT_QIDS,
    WikidataClient,
    WikiDataError,
    WikiEntity,
    pick_parent,
    preferred_parent_qids,
)


@dataclass
class _Budget:
    remaining: int
    exhausted: bool = False

    def take(self) -> bool:
        if self.remaining <= 0:
            self.exhausted = True
            return False
        self.remaining -= 1
        return True


@dataclass
class _FetchState:
    incomplete: bool = False


def load_knowledge_graph(
    session: Session,
    *,
    user_id: UUID,
    topic: str | None,
    category_id: int | None,
    up_depth: int | None,
    down_depth: int | None,
    api: WikidataClient | None = None,
) -> dict:
    settings = get_settings()
    up = _clamp(up_depth, settings.wikidata_default_up_depth, settings.wikidata_max_depth)
    down = _clamp(down_depth, settings.wikidata_default_down_depth, settings.wikidata_max_depth)
    owned = api is None
    client = api or WikidataClient()
    try:
        focus = _resolve(session, client, topic=topic, item_id=category_id)
        state = _FetchState()
        budget = _Budget(settings.wikidata_max_items_per_request)
        ttl = timedelta(days=settings.wikidata_cache_ttl_days)
        if up > 0:
            _ensure_upstream(session, client, focus, up, budget, ttl, state, set())
        if down > 0:
            _ensure_downstream(session, client, focus, down, budget, ttl, state, set())
        parent = _preferred_parent(session, focus)
        if parent is not None:
            _ensure_downstream(session, client, parent, 1, budget, ttl, state, set())
        payload = _subgraph(session, focus, up, down, incomplete=state.incomplete or budget.exhausted)
        request = KnowledgeGraphRequest(user_id=user_id, focus_item_id=focus.id)
        session.add(request)
        session.flush()
        for node in payload["nodes"]:
            item = session.exec(select(KnowledgeItem).where(KnowledgeItem.wikidata_qid == int(node["id"]))).first()
            if item is None:
                continue
            session.add(
                KnowledgeGraphRequestNode(request_id=request.id, item_id=item.id, distance=int(node["distance"]))
            )
        session.flush()
        return payload
    finally:
        close = getattr(client, "close", None) if owned else None
        if close is not None:
            close()


def _resolve(session: Session, api: WikidataClient, *, topic: str | None, item_id: int | None) -> KnowledgeItem:
    if item_id is not None:
        return _resolve_qid(session, api, item_id)
    name = (topic or "").strip()
    if not name:
        raise AppError("VALIDATION_ERROR", "Provide a topic or a category_id", 422)
    stored = list(session.exec(select(KnowledgeItem).where(func.lower(KnowledgeItem.title) == name.lower())).all())
    if len(stored) == 1:
        return stored[0]
    if len(stored) > 1:
        _raise_ambiguous([{"wikidata_qid": row.wikidata_qid, "title": row.title} for row in _sorted_rows(stored)])
    try:
        matches = api.search(name)
    except WikiDataError as exc:
        raise _unavailable() from exc
    exact = [item for item in matches if same_topic(item.title, name)]
    chosen = exact[0] if len(exact) == 1 else matches[0] if len(matches) == 1 else None
    if chosen is not None:
        return _upsert(session, chosen)
    if len(matches) > 1:
        _raise_ambiguous(
            [
                {"wikidata_qid": item.qid, "title": item.title}
                for item in sorted(matches, key=lambda item: (item.title.lower(), item.qid))
            ]
        )
    raise not_found("No Wikidata item matched this topic")


def _resolve_qid(session: Session, api: WikidataClient, qid: int) -> KnowledgeItem:
    existing = session.exec(select(KnowledgeItem).where(KnowledgeItem.wikidata_qid == qid)).first()
    if existing is not None:
        return existing
    try:
        found = api.entities([qid])
    except WikiDataError as exc:
        raise _unavailable() from exc
    entity = found[0] if found else None
    if entity is None or entity.skipped:
        raise not_found("No Wikidata item matched this topic")
    return _upsert(session, entity)


def _ensure_upstream(
    session: Session,
    api: WikidataClient,
    item: KnowledgeItem,
    depth_left: int,
    budget: _Budget,
    ttl: timedelta,
    state: _FetchState,
    seen: set[UUID],
) -> None:
    if item.id in seen:
        return
    seen.add(item.id)
    if depth_left <= 0:
        return
    if item.wikidata_qid in DOMAIN_ROOT_QIDS:
        if not item.upstream_complete:
            item.upstream_complete = True
            item.upstream_fetched_at = utcnow()
            item.domain_qid = item.wikidata_qid
            session.add(item)
            session.flush()
        return
    if not _fresh(item.upstream_fetched_at, item.upstream_complete, ttl):
        if not budget.take():
            state.incomplete = True
            return
        try:
            entity = _entity(api, item.wikidata_qid)
            parent_qids = preferred_parent_qids(entity)
            parents = [row for row in api.entities(parent_qids) if not row.skipped]
        except WikiDataError:
            state.incomplete = True
            return
        chosen = pick_parent(entity, parents)
        stored = [_upsert(session, chosen)] if chosen is not None else []
        relation = "parent_taxon" if entity.parent_taxon else "subclass_of"
        _replace_parents(session, item, stored, relation)
        if chosen is not None and chosen.qid in DOMAIN_ROOT_QIDS:
            item.domain_qid = chosen.qid
        elif chosen is not None:
            parent_row = stored[0]
            if parent_row.domain_qid is not None:
                item.domain_qid = parent_row.domain_qid
        session.add(item)
        session.flush()
    if not item.upstream_complete:
        state.incomplete = True
        return
    for parent in _parents(session, item):
        _ensure_upstream(session, api, parent, depth_left - 1, budget, ttl, state, seen)
        if parent.domain_qid is not None and item.domain_qid is None:
            item.domain_qid = parent.domain_qid
            session.add(item)
            session.flush()


def _ensure_downstream(
    session: Session,
    api: WikidataClient,
    item: KnowledgeItem,
    depth_left: int,
    budget: _Budget,
    ttl: timedelta,
    state: _FetchState,
    seen: set[UUID],
) -> None:
    if item.id in seen:
        return
    seen.add(item.id)
    if depth_left <= 0:
        return
    if not _fresh(item.downstream_fetched_at, item.downstream_complete, ttl):
        if not budget.take():
            state.incomplete = True
            return
        try:
            child_ids = api.children(item.wikidata_qid)
            entities = [row for row in api.entities(child_ids) if not row.skipped]
        except WikiDataError:
            state.incomplete = True
            return
        children = [_upsert(session, entity) for entity in sorted(entities, key=lambda row: (-row.sitelinks, row.title.lower(), row.qid))]
        relation = "parent_taxon" if any(entity.parent_taxon and item.wikidata_qid in entity.parent_taxon for entity in entities) else "subclass_of"
        _replace_children(session, item, children, relation)
    if not item.downstream_complete:
        state.incomplete = True
        return
    for child in _children(session, item):
        _ensure_downstream(session, api, child, depth_left - 1, budget, ttl, state, seen)


def _entity(api: WikidataClient, qid: int) -> WikiEntity:
    found = api.entities([qid])
    if not found:
        raise WikiDataError("Wikidata item is missing")
    return found[0]


def _upsert(session: Session, entity: WikiEntity) -> KnowledgeItem:
    row = session.exec(select(KnowledgeItem).where(KnowledgeItem.wikidata_qid == entity.qid)).first()
    domain = entity.qid if entity.qid in DOMAIN_ROOT_QIDS else None
    if row is None:
        row = KnowledgeItem(
            wikidata_qid=entity.qid,
            title=entity.title,
            description=entity.description,
            domain_qid=domain,
        )
        session.add(row)
    else:
        row.title = entity.title
        if entity.description:
            row.description = entity.description
        if domain is not None:
            row.domain_qid = domain
    session.flush()
    return row


def _replace_parents(session: Session, item: KnowledgeItem, parents: list[KnowledgeItem], relation: str) -> None:
    parent_ids = {parent.id for parent in parents if parent.id != item.id}
    existing = list(session.exec(select(KnowledgeItemEdge).where(KnowledgeItemEdge.child_item_id == item.id)).all())
    have = {edge.parent_item_id: edge for edge in existing}
    for edge in existing:
        if edge.parent_item_id not in parent_ids:
            session.delete(edge)
    for parent in parents:
        if parent.id == item.id:
            continue
        previous = have.get(parent.id)
        if previous is None:
            session.add(KnowledgeItemEdge(parent_item_id=parent.id, child_item_id=item.id, relation=relation))
        else:
            previous.relation = relation
    item.upstream_complete = True
    item.upstream_fetched_at = utcnow()
    session.flush()


def _replace_children(session: Session, item: KnowledgeItem, children: list[KnowledgeItem], relation: str) -> None:
    child_ids = {child.id for child in children if child.id != item.id}
    existing = list(session.exec(select(KnowledgeItemEdge).where(KnowledgeItemEdge.parent_item_id == item.id)).all())
    have = {edge.child_item_id: edge for edge in existing}
    for edge in existing:
        if edge.child_item_id not in child_ids:
            session.delete(edge)
    for child in children:
        if child.id == item.id:
            continue
        previous = have.get(child.id)
        if previous is None:
            session.add(KnowledgeItemEdge(parent_item_id=item.id, child_item_id=child.id, relation=relation))
        else:
            previous.relation = relation
    item.downstream_complete = True
    item.downstream_fetched_at = utcnow()
    session.flush()


def _parents(session: Session, item: KnowledgeItem) -> list[KnowledgeItem]:
    edges = list(session.exec(select(KnowledgeItemEdge).where(KnowledgeItemEdge.child_item_id == item.id)).all())
    return _items(session, [edge.parent_item_id for edge in edges])


def _preferred_parent(session: Session, item: KnowledgeItem) -> KnowledgeItem | None:
    parents = _parents(session, item)
    return parents[0] if parents else None


def _children(session: Session, item: KnowledgeItem) -> list[KnowledgeItem]:
    edges = list(session.exec(select(KnowledgeItemEdge).where(KnowledgeItemEdge.parent_item_id == item.id)).all())
    return _items(session, [edge.child_item_id for edge in edges])


def _items(session: Session, ids: list[UUID]) -> list[KnowledgeItem]:
    if not ids:
        return []
    return list(session.exec(select(KnowledgeItem).where(col(KnowledgeItem.id).in_(ids))).all())


def _subgraph(session: Session, focus: KnowledgeItem, up: int, down: int, *, incomplete: bool) -> dict:
    depths: dict[UUID, int] = {focus.id: 0}
    frontier = [focus]
    for step in range(1, up + 1):
        nxt: list[KnowledgeItem] = []
        for node in frontier:
            for parent in _parents(session, node):
                if parent.id in depths:
                    continue
                depths[parent.id] = -step
                nxt.append(parent)
        frontier = nxt
    frontier = [focus]
    for step in range(1, down + 1):
        nxt = []
        for node in frontier:
            for child in _children(session, node):
                if child.id in depths:
                    continue
                depths[child.id] = step
                nxt.append(child)
        frontier = nxt
    parent = _preferred_parent(session, focus)
    if parent is not None:
        for sibling in _children(session, parent):
            if sibling.id not in depths:
                depths[sibling.id] = 0
    ids = list(depths)
    rows = _items(session, ids)
    by_id = {row.id: row for row in rows}
    edges = _edges_between(session, ids, by_id)
    distances = _distances(focus.id, ids, edges, by_id)
    nodes = [
        {
            "id": by_id[item_id].wikidata_qid,
            "title": by_id[item_id].title,
            "depth": depth,
            "distance": distances.get(item_id, abs(depth)),
        }
        for item_id, depth in depths.items()
        if item_id in by_id
    ]
    nodes.sort(key=lambda node: (node["depth"], node["distance"], str(node["title"]).lower(), node["id"]))
    payload_edges = [
        {"source": parent.wikidata_qid, "target": child.wikidata_qid, "type": "parent_child"}
        for parent_id, child_id in ((edge.parent_item_id, edge.child_item_id) for edge in _stored_edges(session, ids))
        for parent in [by_id.get(parent_id)]
        for child in [by_id.get(child_id)]
        if parent is not None and child is not None
    ]
    payload_edges.sort(key=lambda edge: (edge["source"], edge["target"]))
    return {
        "focus_node_id": focus.wikidata_qid,
        "incomplete": incomplete,
        "nodes": nodes,
        "edges": payload_edges,
    }


def _stored_edges(session: Session, ids: list[UUID]) -> list[KnowledgeItemEdge]:
    if not ids:
        return []
    return list(
        session.exec(
            select(KnowledgeItemEdge).where(
                col(KnowledgeItemEdge.parent_item_id).in_(ids),
                col(KnowledgeItemEdge.child_item_id).in_(ids),
            )
        ).all()
    )


def _edges_between(
    session: Session, ids: list[UUID], by_id: dict[UUID, KnowledgeItem]
) -> list[tuple[UUID, UUID]]:
    _ = by_id
    return [(edge.parent_item_id, edge.child_item_id) for edge in _stored_edges(session, ids)]


def _distances(
    origin: UUID,
    ids: list[UUID],
    edges: list[tuple[UUID, UUID]],
    by_id: dict[UUID, KnowledgeItem],
) -> dict[UUID, int]:
    _ = by_id
    neighbors: dict[UUID, set[UUID]] = {item_id: set() for item_id in ids}
    for parent_id, child_id in edges:
        if parent_id in neighbors and child_id in neighbors:
            neighbors[parent_id].add(child_id)
            neighbors[child_id].add(parent_id)
    found: dict[UUID, int] = {origin: 0}
    queue: deque[UUID] = deque([origin])
    while queue:
        current = queue.popleft()
        for neighbor in neighbors.get(current, ()):
            if neighbor in found:
                continue
            found[neighbor] = found[current] + 1
            queue.append(neighbor)
    return found


def _fresh(fetched_at: datetime | None, complete: bool, ttl: timedelta) -> bool:
    if not complete or fetched_at is None:
        return False
    moment = fetched_at if fetched_at.tzinfo is not None else fetched_at.replace(tzinfo=utcnow().tzinfo)
    return utcnow() - moment < ttl


def _clamp(value: int | None, default: int, maximum: int) -> int:
    chosen = default if value is None else value
    if chosen < 0:
        return 0
    if chosen > maximum:
        return maximum
    return chosen


def _sorted_rows(rows: list[KnowledgeItem]) -> list[KnowledgeItem]:
    return sorted(rows, key=lambda row: (row.title.lower(), row.wikidata_qid))


def _raise_ambiguous(candidates: list[dict]) -> None:
    raise AppError(
        "AMBIGUOUS_ITEM",
        "More than one Wikidata item matches this topic",
        409,
        {"candidates": candidates},
    )


def _unavailable() -> AppError:
    return AppError("WIKIDATA_UNAVAILABLE", "Wikidata could not be reached", 503)
