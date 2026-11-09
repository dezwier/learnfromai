"""One shared Wikipedia category graph.

Categories and parent→child edges are stored once. A later topic reuses whatever
is already complete and still inside the cache window, and asks Wikipedia only
for directions that are missing or stale.
"""

from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime, timedelta
from uuid import UUID

from sqlmodel import Session, col, func, select

from app.core.config import get_settings
from app.core.errors import AppError, not_found
from app.core.time import utcnow
from app.features.knowledge_graph.category_models import (
    KnowledgeCategory,
    KnowledgeCategoryEdge,
    KnowledgeGraphRequest,
)
from app.features.knowledge_graph.identity import canonical_key_for
from app.features.knowledge_graph.models import Concept
from app.features.knowledge_graph.wikipedia import (
    WikiError,
    WikiPage,
    WikipediaClient,
    categories_of_page,
    child_pages,
    display_title,
    lookup_category,
    page_by_id,
    pages_by_ids,
    parent_pages,
    search_page_ids,
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
    api: WikipediaClient | None = None,
) -> dict:
    settings = get_settings()
    up = _clamp(up_depth, settings.wikipedia_default_up_depth, settings.wikipedia_max_depth)
    down = _clamp(down_depth, settings.wikipedia_default_down_depth, settings.wikipedia_max_depth)
    owned = api is None
    client = api or WikipediaClient()
    try:
        focus = _resolve(session, client, topic=topic, category_id=category_id)
        state = _FetchState()
        budget = _Budget(settings.wikipedia_max_categories_per_request)
        ttl = timedelta(days=settings.wikipedia_cache_ttl_days)
        if up > 0:
            _ensure_upstream(session, client, focus, up, budget, ttl, state, set())
        if down > 0:
            _ensure_downstream(session, client, focus, down, budget, ttl, state, set())
        payload = _subgraph(session, focus, up, down, incomplete=state.incomplete or budget.exhausted)
        session.add(KnowledgeGraphRequest(user_id=user_id, focus_category_id=focus.id))
        session.flush()
        return payload
    finally:
        close = getattr(client, "close", None) if owned else None
        if close is not None:
            close()


def _resolve(session: Session, api: WikipediaClient, *, topic: str | None, category_id: int | None) -> KnowledgeCategory:
    if category_id is not None:
        return _resolve_page(session, api, category_id)
    name = display_title(topic or "")
    if not name:
        raise AppError("VALIDATION_ERROR", "Provide a topic or a category_id", 422)
    stored = list(
        session.exec(select(KnowledgeCategory).where(func.lower(KnowledgeCategory.title) == name.lower())).all()
    )
    if len(stored) == 1:
        return stored[0]
    if len(stored) > 1:
        _raise_ambiguous(
            [{"wikipedia_page_id": row.wikipedia_page_id, "title": row.title} for row in _sorted_rows(stored)]
        )
    try:
        direct = lookup_category(api, name)
    except WikiError as exc:
        raise _unavailable() from exc
    if direct is not None:
        return _upsert(session, direct)
    try:
        candidates = _candidate_pages(api, name)
    except WikiError as exc:
        raise _unavailable() from exc
    exact = [page for page in candidates if canonical_key_for(page.title) == canonical_key_for(name)]
    chosen = exact[0] if len(exact) == 1 else candidates[0] if len(candidates) == 1 else None
    if chosen is not None:
        return _upsert(session, chosen)
    if len(candidates) > 1:
        _raise_ambiguous(
            [
                {"wikipedia_page_id": page.page_id, "title": page.title}
                for page in sorted(candidates, key=lambda page: (page.title.lower(), page.page_id))
            ]
        )
    raise not_found("No Wikipedia category matched this topic")


def _resolve_page(session: Session, api: WikipediaClient, page_id: int) -> KnowledgeCategory:
    existing = session.exec(select(KnowledgeCategory).where(KnowledgeCategory.wikipedia_page_id == page_id)).first()
    if existing is not None:
        return existing
    try:
        page = page_by_id(api, page_id)
    except WikiError as exc:
        raise _unavailable() from exc
    if page is None or page.hidden or page.namespace != 14:
        raise not_found("No Wikipedia category matched this topic")
    return _upsert(session, page)


def _candidate_pages(api: WikipediaClient, name: str) -> list[WikiPage]:
    by_id: dict[int, WikiPage] = {}
    searched = search_page_ids(api, name, namespace=14, limit=8)
    for page in pages_by_ids(api, searched):
        if page.namespace == 14 and not page.hidden:
            by_id[page.page_id] = page
    articles = search_page_ids(api, name, namespace=0, limit=1)
    for article_id in articles:
        for page in categories_of_page(api, article_id):
            by_id.setdefault(page.page_id, page)
    return list(by_id.values())


def _ensure_upstream(
    session: Session,
    api: WikipediaClient,
    category: KnowledgeCategory,
    depth_left: int,
    budget: _Budget,
    ttl: timedelta,
    state: _FetchState,
    seen: set[UUID],
) -> None:
    if category.id in seen:
        return
    seen.add(category.id)
    if depth_left <= 0:
        return
    if not _fresh(category.upstream_fetched_at, category.upstream_complete, ttl):
        if not budget.take():
            state.incomplete = True
            return
        try:
            pages = parent_pages(api, category.wikipedia_page_id)
        except WikiError:
            state.incomplete = True
            return
        parents = [_upsert(session, page) for page in pages]
        _replace_parents(session, category, parents)
    if not category.upstream_complete:
        state.incomplete = True
        return
    for parent in _parents(session, category):
        _ensure_upstream(session, api, parent, depth_left - 1, budget, ttl, state, seen)


def _ensure_downstream(
    session: Session,
    api: WikipediaClient,
    category: KnowledgeCategory,
    depth_left: int,
    budget: _Budget,
    ttl: timedelta,
    state: _FetchState,
    seen: set[UUID],
) -> None:
    if category.id in seen:
        return
    seen.add(category.id)
    if depth_left <= 0:
        return
    if not _fresh(category.downstream_fetched_at, category.downstream_complete, ttl):
        if not budget.take():
            state.incomplete = True
            return
        try:
            pages = child_pages(api, category.wikipedia_page_id)
        except WikiError:
            state.incomplete = True
            return
        children = [_upsert(session, page) for page in pages]
        _replace_children(session, category, children)
    if not category.downstream_complete:
        state.incomplete = True
        return
    for child in _children(session, category):
        _ensure_downstream(session, api, child, depth_left - 1, budget, ttl, state, seen)


def _upsert(session: Session, page: WikiPage) -> KnowledgeCategory:
    row = session.exec(select(KnowledgeCategory).where(KnowledgeCategory.wikipedia_page_id == page.page_id)).first()
    if row is None:
        row = KnowledgeCategory(
            wikipedia_page_id=page.page_id,
            title=page.title,
            description=page.description,
        )
        session.add(row)
    else:
        row.title = page.title
        if page.description:
            row.description = page.description
    session.flush()
    _link_concepts(session, row)
    return row


def _link_concepts(session: Session, category: KnowledgeCategory) -> None:
    """Attach an existing concept when the titles are the same idea. Leave its learning text alone."""
    key = canonical_key_for(category.title)
    rows = list(session.exec(select(Concept).where(Concept.canonical_key == key)).all())
    titled = list(session.exec(select(Concept).where(func.lower(Concept.title) == category.title.lower())).all())
    seen: set[UUID] = set()
    for concept in [*rows, *titled]:
        if concept.id in seen:
            continue
        seen.add(concept.id)
        if canonical_key_for(concept.title) != key:
            continue
        if concept.knowledge_category_id is not None:
            continue
        concept.knowledge_category_id = category.id


def _replace_parents(session: Session, category: KnowledgeCategory, parents: list[KnowledgeCategory]) -> None:
    parent_ids = {parent.id for parent in parents if parent.id != category.id}
    existing = list(
        session.exec(select(KnowledgeCategoryEdge).where(KnowledgeCategoryEdge.child_category_id == category.id)).all()
    )
    have = {edge.parent_category_id for edge in existing}
    for edge in existing:
        if edge.parent_category_id not in parent_ids:
            session.delete(edge)
    for parent_id in parent_ids:
        if parent_id not in have:
            session.add(KnowledgeCategoryEdge(parent_category_id=parent_id, child_category_id=category.id))
    category.upstream_complete = True
    category.upstream_fetched_at = utcnow()
    session.flush()


def _replace_children(session: Session, category: KnowledgeCategory, children: list[KnowledgeCategory]) -> None:
    child_ids = {child.id for child in children if child.id != category.id}
    existing = list(
        session.exec(select(KnowledgeCategoryEdge).where(KnowledgeCategoryEdge.parent_category_id == category.id)).all()
    )
    have = {edge.child_category_id for edge in existing}
    for edge in existing:
        if edge.child_category_id not in child_ids:
            session.delete(edge)
    for child_id in child_ids:
        if child_id not in have:
            session.add(KnowledgeCategoryEdge(parent_category_id=category.id, child_category_id=child_id))
    category.downstream_complete = True
    category.downstream_fetched_at = utcnow()
    session.flush()


def _parents(session: Session, category: KnowledgeCategory) -> list[KnowledgeCategory]:
    edges = list(
        session.exec(select(KnowledgeCategoryEdge).where(KnowledgeCategoryEdge.child_category_id == category.id)).all()
    )
    return _categories(session, [edge.parent_category_id for edge in edges])


def _children(session: Session, category: KnowledgeCategory) -> list[KnowledgeCategory]:
    edges = list(
        session.exec(select(KnowledgeCategoryEdge).where(KnowledgeCategoryEdge.parent_category_id == category.id)).all()
    )
    return _categories(session, [edge.child_category_id for edge in edges])


def _categories(session: Session, ids: list[UUID]) -> list[KnowledgeCategory]:
    if not ids:
        return []
    return list(session.exec(select(KnowledgeCategory).where(col(KnowledgeCategory.id).in_(ids))).all())


def _subgraph(session: Session, focus: KnowledgeCategory, up: int, down: int, *, incomplete: bool) -> dict:
    depths: dict[UUID, int] = {focus.id: 0}
    frontier = [focus]
    for step in range(1, up + 1):
        nxt: list[KnowledgeCategory] = []
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
    ids = list(depths)
    rows = _categories(session, ids)
    by_id = {row.id: row for row in rows}
    edges = _edges_between(session, ids, by_id)
    nodes = [
        {"id": by_id[item_id].wikipedia_page_id, "title": by_id[item_id].title, "depth": depth}
        for item_id, depth in depths.items()
        if item_id in by_id
    ]
    nodes.sort(key=lambda node: (node["depth"], str(node["title"]).lower(), node["id"]))
    edges.sort(key=lambda edge: (edge["source"], edge["target"]))
    return {
        "focus_node_id": focus.wikipedia_page_id,
        "incomplete": incomplete,
        "nodes": nodes,
        "edges": edges,
    }


def _edges_between(session: Session, ids: list[UUID], by_id: dict[UUID, KnowledgeCategory]) -> list[dict]:
    if not ids:
        return []
    stored = session.exec(
        select(KnowledgeCategoryEdge).where(
            col(KnowledgeCategoryEdge.parent_category_id).in_(ids),
            col(KnowledgeCategoryEdge.child_category_id).in_(ids),
        )
    ).all()
    edges: list[dict] = []
    for edge in stored:
        parent = by_id.get(edge.parent_category_id)
        child = by_id.get(edge.child_category_id)
        if parent is None or child is None:
            continue
        edges.append({"source": parent.wikipedia_page_id, "target": child.wikipedia_page_id, "type": "parent_child"})
    return edges


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


def _sorted_rows(rows: list[KnowledgeCategory]) -> list[KnowledgeCategory]:
    return sorted(rows, key=lambda row: (row.title.lower(), row.wikipedia_page_id))


def _raise_ambiguous(candidates: list[dict]) -> None:
    raise AppError(
        "AMBIGUOUS_CATEGORY",
        "More than one Wikipedia category matches this topic",
        409,
        {"candidates": candidates},
    )


def _unavailable() -> AppError:
    return AppError("WIKIPEDIA_UNAVAILABLE", "Wikipedia could not be reached", 503)
