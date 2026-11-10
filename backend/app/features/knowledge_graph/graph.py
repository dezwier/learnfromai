"""One shared Wikidata + Wikipedia knowledge graph.

Nodes are keyed by Wikidata qid. Hierarchy edges come from P279/P171.
Related edges come from Wikipedia morelike. Each signed-in focus stores
per-request hop distances on the returned set.
"""

from __future__ import annotations

from collections import deque
from dataclasses import dataclass
from datetime import timedelta
from uuid import UUID

from sqlmodel import Session, col, func, select

from app.core.config import get_settings
from app.core.errors import AppError, not_found
from app.core.time import utcnow
from app.features.knowledge_graph.identity import same_topic
from app.features.knowledge_graph.node_models import (
    KnowledgeEdge,
    KnowledgeNode,
    KnowledgeRequest,
    KnowledgeRequestNode,
)
from app.features.knowledge_graph.wikidata import (
    DOMAIN_ROOT_QIDS,
    WikidataClient,
    WikiDataError,
    WikiEntity,
    pick_parent,
    preferred_parent_qids,
)
from app.features.knowledge_graph.wikipedia_related import WikipediaError, WikipediaRelatedClient

CHILD_CAP = 8
RELATED_PER_RADIUS = 8
RELATION_SUBCLASS = "subclass_of"
RELATION_TAXON = "parent_taxon"
RELATION_RELATED = "related_to"


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
    topic: str | None = None,
    focus_qid: int | None = None,
    up_depth: int | None = None,
    down_depth: int | None = None,
    cloud_radius: int | None = None,
    wikidata: WikidataClient | None = None,
    wikipedia: WikipediaRelatedClient | None = None,
) -> dict:
    settings = get_settings()
    up = _clamp(up_depth, settings.wikidata_default_up_depth, settings.wikidata_max_depth)
    down = _clamp(down_depth, settings.wikidata_default_down_depth, settings.wikidata_max_depth)
    cloud = _clamp(cloud_radius, settings.wikidata_default_cloud_radius, settings.wikidata_max_cloud_radius)
    if (topic is None or not str(topic).strip()) and focus_qid is None:
        return _resume_latest(session, user_id=user_id, up=up, down=down, cloud=cloud, wikidata=wikidata, wikipedia=wikipedia)

    own_wd = wikidata is None
    own_wp = wikipedia is None
    api = wikidata or WikidataClient()
    related_api = wikipedia or WikipediaRelatedClient()
    try:
        focus = _resolve(session, api, topic=topic, qid=focus_qid)
        state = _FetchState()
        budget = _Budget(settings.wikidata_max_items_per_request)
        ttl = timedelta(days=settings.wikidata_cache_ttl_days)
        if up > 0:
            _ensure_upstream(session, api, focus, up, budget, ttl, state, set())
        if down > 0:
            _ensure_downstream(session, api, focus, budget, ttl, state)
        if cloud > 0:
            _ensure_related(session, api, related_api, focus, cloud, budget, ttl, state)
        payload = _subgraph(session, focus, up=up, down=1 if down > 0 else 0, cloud=cloud, incomplete=state.incomplete or budget.exhausted)
        request = KnowledgeRequest(
            user_id=user_id,
            focus_qid=focus.qid,
            up_depth=up,
            down_depth=down,
            cloud_radius=cloud,
        )
        session.add(request)
        session.flush()
        for node in payload["nodes"]:
            session.add(
                KnowledgeRequestNode(request_id=request.id, qid=int(node["id"]), distance=int(node["distance"]))
            )
        session.flush()
        payload["request_id"] = str(request.id)
        return payload
    finally:
        if own_wd:
            api.close()
        if own_wp:
            related_api.close()


def _resume_latest(
    session: Session,
    *,
    user_id: UUID,
    up: int,
    down: int,
    cloud: int,
    wikidata: WikidataClient | None,
    wikipedia: WikipediaRelatedClient | None,
) -> dict:
    latest = session.exec(
        select(KnowledgeRequest).where(KnowledgeRequest.user_id == user_id).order_by(col(KnowledgeRequest.created_at).desc())
    ).first()
    if latest is None:
        return {"focus_node_id": None, "incomplete": False, "request_id": None, "nodes": [], "edges": []}
    return load_knowledge_graph(
        session,
        user_id=user_id,
        topic=None,
        focus_qid=latest.focus_qid,
        up_depth=latest.up_depth or up,
        down_depth=latest.down_depth or down,
        cloud_radius=latest.cloud_radius or cloud,
        wikidata=wikidata,
        wikipedia=wikipedia,
    )


def _resolve(session: Session, api: WikidataClient, *, topic: str | None, qid: int | None) -> KnowledgeNode:
    if qid is not None:
        return _resolve_qid(session, api, qid)
    name = (topic or "").strip()
    if not name:
        raise AppError("VALIDATION_ERROR", "Provide a topic or a focus_qid", 422)
    stored = list(session.exec(select(KnowledgeNode).where(func.lower(KnowledgeNode.title) == name.lower())).all())
    if len(stored) == 1:
        return stored[0]
    if len(stored) > 1:
        _raise_ambiguous(
            [{"wikidata_qid": row.qid, "title": row.title, "description": row.description} for row in _sorted_nodes(stored)]
        )
    try:
        matches = api.search(name)
    except WikiDataError as exc:
        raise _unavailable() from exc
    chosen = _pick_match(name, matches)
    if chosen is not None:
        return _upsert(session, chosen)
    if matches:
        ranked = sorted(matches, key=_match_rank, reverse=True)
        _raise_ambiguous(
            [{"wikidata_qid": item.qid, "title": item.title, "description": item.description} for item in ranked]
        )
    raise not_found("No Wikidata item matched this topic")


def _match_rank(item: WikiEntity) -> tuple:
    return (1 if item.parent_taxon or item.subclass_of else 0, item.sitelinks, -item.qid)


def _pick_match(name: str, matches: list[WikiEntity]) -> WikiEntity | None:
    if not matches:
        return None
    if len(matches) == 1:
        return matches[0]
    exact = [item for item in matches if same_topic(item.title, name)]
    pool = exact or matches
    ranked = sorted(pool, key=_match_rank, reverse=True)
    best = ranked[0]
    if len(ranked) == 1:
        return best
    second = ranked[1]
    if best.sitelinks >= max(8, second.sitelinks * 3):
        return best
    if best.sitelinks > second.sitelinks and (best.parent_taxon or best.subclass_of) and not (
        second.parent_taxon or second.subclass_of
    ):
        return best
    return None


def _resolve_qid(session: Session, api: WikidataClient, qid: int) -> KnowledgeNode:
    existing = session.get(KnowledgeNode, qid)
    if existing is not None:
        return existing
    try:
        found = api.entities([qid])
    except WikiDataError as exc:
        raise _unavailable() from exc
    if not found:
        raise not_found("Wikidata item not found")
    return _upsert(session, found[0])


def _ensure_upstream(
    session: Session,
    api: WikidataClient,
    node: KnowledgeNode,
    remaining: int,
    budget: _Budget,
    ttl: timedelta,
    state: _FetchState,
    visiting: set[int],
) -> None:
    if remaining <= 0 or node.qid in DOMAIN_ROOT_QIDS or node.qid in visiting:
        return
    visiting.add(node.qid)
    if _fresh(node.upstream_fetched_at, node.upstream_complete, ttl):
        parent = _preferred_stored_parent(session, node)
        if parent is not None:
            _ensure_upstream(session, api, parent, remaining - 1, budget, ttl, state, visiting)
        return
    if not budget.take():
        state.incomplete = True
        return
    try:
        entities = api.entities([node.qid])
    except WikiDataError:
        state.incomplete = True
        return
    if not entities:
        state.incomplete = True
        return
    entity = entities[0]
    _upsert(session, entity)
    parent_ids = preferred_parent_qids(entity)
    parents: list[WikiEntity] = []
    if parent_ids:
        if not budget.take():
            state.incomplete = True
            node.upstream_fetched_at = utcnow()
            node.upstream_complete = False
            session.add(node)
            session.flush()
            return
        try:
            parents = [item for item in api.entities(parent_ids) if not item.skipped]
        except WikiDataError:
            state.incomplete = True
            node.upstream_fetched_at = utcnow()
            node.upstream_complete = False
            session.add(node)
            session.flush()
            return
    chosen = pick_parent(entity, parents)
    _replace_hierarchy_parents(session, entity, chosen)
    refreshed = session.get(KnowledgeNode, node.qid) or node
    refreshed.upstream_fetched_at = utcnow()
    refreshed.upstream_complete = True
    session.add(refreshed)
    session.flush()
    if chosen is not None:
        parent_node = _upsert(session, chosen)
        _ensure_upstream(session, api, parent_node, remaining - 1, budget, ttl, state, visiting)


def _ensure_downstream(
    session: Session,
    api: WikidataClient,
    node: KnowledgeNode,
    budget: _Budget,
    ttl: timedelta,
    state: _FetchState,
) -> None:
    if _fresh(node.downstream_fetched_at, node.downstream_complete, ttl):
        return
    if not budget.take():
        state.incomplete = True
        return
    try:
        entities = api.entities([node.qid])
    except WikiDataError:
        state.incomplete = True
        return
    if not entities:
        state.incomplete = True
        return
    entity = entities[0]
    _upsert(session, entity)
    if not budget.take():
        state.incomplete = True
        node.downstream_fetched_at = utcnow()
        node.downstream_complete = False
        session.add(node)
        session.flush()
        return
    try:
        child_ids = api.children(node.qid, taxon=entity.is_taxon)
    except WikiDataError:
        state.incomplete = True
        node.downstream_fetched_at = utcnow()
        node.downstream_complete = False
        session.add(node)
        session.flush()
        return
    children: list[WikiEntity] = []
    if child_ids:
        if not budget.take():
            state.incomplete = True
            node.downstream_fetched_at = utcnow()
            node.downstream_complete = False
            session.add(node)
            session.flush()
            return
        try:
            loaded = [item for item in api.entities(child_ids) if not item.skipped and item.qid != node.qid]
        except WikiDataError:
            state.incomplete = True
            node.downstream_fetched_at = utcnow()
            node.downstream_complete = False
            session.add(node)
            session.flush()
            return
        loaded.sort(key=lambda item: (-item.sitelinks, item.qid))
        children = loaded[:CHILD_CAP]
    relation = RELATION_TAXON if entity.is_taxon else RELATION_SUBCLASS
    _replace_hierarchy_children(session, node, children, relation)
    node.downstream_fetched_at = utcnow()
    node.downstream_complete = True
    session.add(node)
    session.flush()


def _ensure_related(
    session: Session,
    api: WikidataClient,
    related_api: WikipediaRelatedClient,
    node: KnowledgeNode,
    cloud_radius: int,
    budget: _Budget,
    ttl: timedelta,
    state: _FetchState,
) -> None:
    if _fresh(node.related_fetched_at, node.related_complete, ttl):
        return
    if not budget.take():
        state.incomplete = True
        return
    try:
        entities = api.entities([node.qid])
    except WikiDataError:
        state.incomplete = True
        return
    if not entities:
        state.incomplete = True
        return
    entity = entities[0]
    focus = _upsert(session, entity)
    enwiki = focus.enwiki_title or entity.enwiki_title or entity.title
    limit = RELATED_PER_RADIUS * max(cloud_radius, 1)
    try:
        hits = related_api.related(enwiki, limit=limit)
    except WikipediaError:
        state.incomplete = True
        focus.related_fetched_at = utcnow()
        focus.related_complete = False
        session.add(focus)
        session.flush()
        return
    related_nodes: list[KnowledgeNode] = []
    missing_qids = [hit.qid for hit in hits if hit.qid is not None]
    by_qid: dict[int, WikiEntity] = {}
    if missing_qids:
        if not budget.take():
            state.incomplete = True
        else:
            try:
                by_qid = {item.qid: item for item in api.entities(missing_qids) if not item.skipped}
            except WikiDataError:
                state.incomplete = True
    for hit in hits:
        if hit.qid is None:
            continue
        entity_hit = by_qid.get(hit.qid)
        if entity_hit is not None:
            related_nodes.append(_upsert(session, entity_hit))
            continue
        # Keep the Wikipedia join even when Wikidata detail is missing.
        stub = session.get(KnowledgeNode, hit.qid)
        if stub is None:
            stub = KnowledgeNode(qid=hit.qid, title=hit.title, description=hit.description, enwiki_title=hit.title)
            session.add(stub)
            session.flush()
        related_nodes.append(stub)
    _replace_related(session, focus, related_nodes)
    focus.related_fetched_at = utcnow()
    focus.related_complete = True
    session.add(focus)
    session.flush()


def _upsert(session: Session, entity: WikiEntity) -> KnowledgeNode:
    row = session.get(KnowledgeNode, entity.qid)
    if row is None:
        row = KnowledgeNode(qid=entity.qid, title=entity.title)
        session.add(row)
    row.title = entity.title
    row.description = entity.description
    row.enwiki_title = entity.enwiki_title or row.enwiki_title
    if entity.qid in DOMAIN_ROOT_QIDS:
        row.domain_qid = entity.qid
    session.add(row)
    session.flush()
    return row


def _replace_hierarchy_parents(session: Session, child: WikiEntity, parent: WikiEntity | None) -> None:
    existing = list(
        session.exec(
            select(KnowledgeEdge).where(
                KnowledgeEdge.to_qid == child.qid,
                col(KnowledgeEdge.relation).in_([RELATION_SUBCLASS, RELATION_TAXON]),
            )
        ).all()
    )
    for edge in existing:
        session.delete(edge)
    session.flush()
    if parent is None:
        return
    parent_node = _upsert(session, parent)
    if parent.qid in child.subclass_of:
        relation = RELATION_SUBCLASS
    elif parent.qid in child.parent_taxon:
        relation = RELATION_TAXON
    else:
        relation = RELATION_SUBCLASS
    session.add(KnowledgeEdge(from_qid=parent_node.qid, relation=relation, to_qid=child.qid))
    session.flush()


def _replace_hierarchy_children(
    session: Session,
    node: KnowledgeNode,
    children: list[WikiEntity],
    relation: str,
) -> None:
    existing = list(
        session.exec(
            select(KnowledgeEdge).where(
                KnowledgeEdge.from_qid == node.qid,
                col(KnowledgeEdge.relation).in_([RELATION_SUBCLASS, RELATION_TAXON]),
            )
        ).all()
    )
    for edge in existing:
        session.delete(edge)
    session.flush()
    for child in children:
        child_node = _upsert(session, child)
        session.add(KnowledgeEdge(from_qid=node.qid, relation=relation, to_qid=child_node.qid))
    session.flush()


def _replace_related(session: Session, node: KnowledgeNode, related: list[KnowledgeNode]) -> None:
    existing = list(
        session.exec(
            select(KnowledgeEdge).where(KnowledgeEdge.from_qid == node.qid, KnowledgeEdge.relation == RELATION_RELATED)
        ).all()
    )
    for edge in existing:
        session.delete(edge)
    session.flush()
    for other in related:
        if other.qid == node.qid:
            continue
        session.add(KnowledgeEdge(from_qid=node.qid, relation=RELATION_RELATED, to_qid=other.qid))
    session.flush()


def _preferred_stored_parent(session: Session, node: KnowledgeNode) -> KnowledgeNode | None:
    edges = list(
        session.exec(
            select(KnowledgeEdge).where(
                KnowledgeEdge.to_qid == node.qid,
                col(KnowledgeEdge.relation).in_([RELATION_SUBCLASS, RELATION_TAXON]),
            )
        ).all()
    )
    if not edges:
        return None
    return session.get(KnowledgeNode, edges[0].from_qid)


def _subgraph(
    session: Session,
    focus: KnowledgeNode,
    *,
    up: int,
    down: int,
    cloud: int,
    incomplete: bool,
) -> dict:
    nodes: dict[int, KnowledgeNode] = {focus.qid: focus}
    depths: dict[int, int] = {focus.qid: 0}
    kinds: dict[int, str] = {focus.qid: "focus"}

    # Climb preferred parent chain.
    current = focus
    for level in range(1, up + 1):
        parent = _preferred_stored_parent(session, current)
        if parent is None:
            break
        nodes[parent.qid] = parent
        depths[parent.qid] = -level
        kinds[parent.qid] = "parent"
        current = parent

    # Direct children only.
    if down > 0:
        for edge in _hierarchy_out(session, focus.qid):
            child = session.get(KnowledgeNode, edge.to_qid)
            if child is None:
                continue
            nodes[child.qid] = child
            depths.setdefault(child.qid, 1)
            kinds.setdefault(child.qid, "child")

    # Related cloud (no hierarchy walk).
    if cloud > 0:
        for edge in _related_out(session, focus.qid):
            other = session.get(KnowledgeNode, edge.to_qid)
            if other is None:
                continue
            nodes[other.qid] = other
            depths.setdefault(other.qid, 0)
            kinds.setdefault(other.qid, "related")

    ids = list(nodes.keys())
    edges = _stored_edges(session, ids)
    distances = _distances(focus.qid, edges)
    node_payload = []
    for qid in sorted(ids, key=lambda value: (depths.get(value, 0), nodes[value].title.lower(), value)):
        node = nodes[qid]
        node_payload.append(
            {
                "id": node.qid,
                "title": node.title,
                "description": node.description,
                "depth": depths.get(qid, 0),
                "distance": distances.get(qid, 0),
                "kind": kinds.get(qid, "related"),
            }
        )
    edge_payload = [
        {"source": edge.from_qid, "target": edge.to_qid, "type": edge.relation}
        for edge in sorted(edges, key=lambda row: (row.from_qid, row.relation, row.to_qid))
    ]
    return {
        "focus_node_id": focus.qid,
        "incomplete": incomplete,
        "nodes": node_payload,
        "edges": edge_payload,
    }


def _hierarchy_out(session: Session, qid: int) -> list[KnowledgeEdge]:
    return list(
        session.exec(
            select(KnowledgeEdge).where(
                KnowledgeEdge.from_qid == qid,
                col(KnowledgeEdge.relation).in_([RELATION_SUBCLASS, RELATION_TAXON]),
            )
        ).all()
    )


def _related_out(session: Session, qid: int) -> list[KnowledgeEdge]:
    return list(
        session.exec(select(KnowledgeEdge).where(KnowledgeEdge.from_qid == qid, KnowledgeEdge.relation == RELATION_RELATED)).all()
    )


def _stored_edges(session: Session, ids: list[int]) -> list[KnowledgeEdge]:
    if not ids:
        return []
    return list(
        session.exec(
            select(KnowledgeEdge).where(col(KnowledgeEdge.from_qid).in_(ids), col(KnowledgeEdge.to_qid).in_(ids))
        ).all()
    )


def _distances(focus_qid: int, edges: list[KnowledgeEdge]) -> dict[int, int]:
    adjacency: dict[int, set[int]] = {}
    for edge in edges:
        adjacency.setdefault(edge.from_qid, set()).add(edge.to_qid)
        adjacency.setdefault(edge.to_qid, set()).add(edge.from_qid)
    distances = {focus_qid: 0}
    queue: deque[int] = deque([focus_qid])
    while queue:
        current = queue.popleft()
        for neighbor in adjacency.get(current, ()):
            if neighbor in distances:
                continue
            distances[neighbor] = distances[current] + 1
            queue.append(neighbor)
    return distances


def _fresh(fetched_at, complete: bool, ttl: timedelta) -> bool:
    if not complete or fetched_at is None:
        return False
    return utcnow() - fetched_at <= ttl


def _sorted_nodes(rows: list[KnowledgeNode]) -> list[KnowledgeNode]:
    return sorted(rows, key=lambda row: (row.title.lower(), row.qid))


def _raise_ambiguous(candidates: list[dict]) -> None:
    raise AppError(
        "AMBIGUOUS_TOPIC",
        "More than one Wikidata item matches this topic",
        409,
        details={"candidates": candidates},
    )


def _unavailable() -> AppError:
    return AppError("WIKIDATA_UNAVAILABLE", "Wikidata is temporarily unavailable", 503)


def _clamp(value: int | None, default: int, maximum: int) -> int:
    if value is None:
        return default
    return max(0, min(int(value), maximum))
