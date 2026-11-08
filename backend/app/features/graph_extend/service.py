from __future__ import annotations

from uuid import UUID

from sqlmodel import Session, select

from app.core.config import get_settings
from app.features.graph_extend.models import ExtendRequest
from app.features.knowledge_graph.domain import DIRECTED_TYPES, EDGE_TYPES, creates_cycle
from app.features.knowledge_graph.hierarchy import assign_levels
from app.features.knowledge_graph.placement import seat_branch
from app.features.knowledge_graph.identity import (
    canonical_key_for,
    explanation_covers,
    is_placeholder_title,
    same_topic,
)
from app.features.knowledge_graph.models import Concept, Edge, Graph


def apply_branch(
    session: Session,
    *,
    graph: Graph,
    parent_concept_id: UUID | None,
    branch: dict,
    instruction: str | None = None,
    extend_request_id: UUID | None = None,
) -> dict:
    """Insert the model's nodes and edges, reusing concepts that already exist.

    The graph row is locked for the write. Contains and prerequisite edges that
    would cycle are skipped. A dangling edge is skipped. A new node left with
    no edges, while the rest of the branch is connected, is removed.
    """
    session.exec(select(Graph).where(Graph.id == graph.id).with_for_update()).one()
    if extend_request_id is not None:
        cached = session.get(ExtendRequest, extend_request_id)
        if cached is not None:
            session.expire(cached)
        if session.get(ExtendRequest, extend_request_id) is None:
            return {"added_nodes": 0, "added_edges": 0, "truncated": False}
    concepts = list(session.exec(select(Concept).where(Concept.origin_graph_id == graph.id)).all())
    edges = list(session.exec(select(Edge).where(Edge.graph_id == graph.id)).all())
    by_id = {concept.id: concept for concept in concepts}
    catalog = _catalog(concepts)
    parent = by_id.get(parent_concept_id) if parent_concept_id else None
    if parent is None and instruction and instruction.strip():
        seat_branch(branch, instruction, [_snapshot(concept) for concept in concepts])

    raw_nodes = [node for node in (branch.get("nodes") or []) if isinstance(node, dict)]
    known_titles = {concept.title for concept in concepts} | {str(node.get("title") or "") for node in raw_nodes}
    kept_nodes = [node for node in raw_nodes if not _skip_node(node, known_titles)]
    cap = get_settings().graph_expansion_max_nodes
    truncated = bool(branch.get("truncated")) or len(kept_nodes) > cap
    kept_nodes = kept_nodes[:cap]

    temp_ids: dict[str, UUID] = {}
    created: list[Concept] = []
    for index, node in enumerate(kept_nodes):
        title = str(node.get("title") or "").strip()
        key = canonical_key_for(str(node.get("canonical_key") or title))
        temp = str(node.get("temp_id") or f"n{index}")
        if parent is not None and (same_topic(title, parent.title) or key == (parent.canonical_key or "")):
            temp_ids[temp] = parent.id
            _merge_explanation(parent, node)
            continue
        referenced = _referenced_concept(node, by_id)
        if referenced is not None:
            temp_ids[temp] = referenced.id
            _merge_explanation(referenced, node)
            continue
        existing = _match(catalog, title, key, _proposed_level(node))
        if existing is not None:
            temp_ids[temp] = existing.id
            _merge_explanation(existing, node)
            continue
        concept = Concept(
            origin_graph_id=graph.id,
            title=title,
            summary=str(node.get("summary") or "").strip(),
            explanation=str(node.get("explanation") or "").strip(),
            level=_proposed_level(node) or 0,
            canonical_key=key,
            extend_request_id=extend_request_id,
        )
        session.add(concept)
        session.flush()
        created.append(concept)
        by_id[concept.id] = concept
        catalog[key] = concept
        temp_ids[temp] = concept.id

    directed: dict[UUID, set[UUID]] = {}
    seen_edges: set[tuple[UUID, UUID, str]] = set()
    primary_targets: set[UUID] = set()
    for edge in edges:
        seen_edges.add((edge.from_concept_id, edge.to_concept_id, edge.type))
        if edge.type in DIRECTED_TYPES:
            directed.setdefault(edge.from_concept_id, set()).add(edge.to_concept_id)
        if edge.type == "contains" and edge.is_primary_parent:
            primary_targets.add(edge.to_concept_id)

    added_edges: list[Edge] = []
    for edge in _candidate_edges(branch):
        _consider_edge(
            session,
            graph,
            edge,
            temp_ids,
            by_id,
            seen_edges,
            directed,
            primary_targets,
            added_edges,
            extend_request_id,
        )

    incident = {concept_id for edge in added_edges for concept_id in (edge.from_concept_id, edge.to_concept_id)}
    branch_ids = set(temp_ids.values())
    deleted: set[UUID] = set()
    if branch_ids & incident:
        for concept in created:
            if concept.id in incident:
                continue
            session.delete(concept)
            deleted.add(concept.id)
        if deleted:
            session.flush()
            temp_ids = {temp: concept_id for temp, concept_id in temp_ids.items() if concept_id not in deleted}

    if parent is not None:
        linked = {item.to_concept_id for item in added_edges if item.type == "contains"}
        linked.update(item.to_concept_id for item in edges if item.type == "contains")
        for concept_id in dict.fromkeys(temp_ids.values()):
            if concept_id == parent.id or concept_id in linked or concept_id in deleted:
                continue
            _consider_edge(
                session,
                graph,
                {"from": str(parent.id), "to": str(concept_id), "type": "contains", "is_primary_parent": True},
                temp_ids,
                by_id,
                seen_edges,
                directed,
                primary_targets,
                added_edges,
                extend_request_id,
            )

    live = [concept for concept in by_id.values() if concept.id not in deleted]
    live_edges = [
        edge
        for edge in [*edges, *added_edges]
        if edge.from_concept_id not in deleted and edge.to_concept_id not in deleted
    ]
    assign_levels(live, live_edges)
    return {
        "added_nodes": len(created) - len(deleted),
        "added_edges": len(added_edges),
        "truncated": truncated,
    }


def _snapshot(concept: Concept) -> dict:
    return {
        "concept_id": str(concept.id),
        "title": concept.title,
        "level": concept.level,
        "explanation": concept.explanation or "",
        "canonical_key": concept.canonical_key or "",
    }


def _skip_node(node: dict, titles: set[str]) -> bool:
    title = str(node.get("title") or "").strip()
    return not title or is_placeholder_title(title, titles)


def _catalog(concepts: list[Concept]) -> dict[str, Concept]:
    catalog: dict[str, Concept] = {}
    for concept in concepts:
        catalog[concept.canonical_key or canonical_key_for(concept.title)] = concept
    return catalog


def _match(catalog: dict[str, Concept], title: str, key: str, proposed_level: int | None) -> Concept | None:
    for candidate in (key, canonical_key_for(title)):
        found = catalog.get(candidate)
        if found is not None:
            return found
        if candidate.endswith("s") and candidate[:-1] in catalog:
            return catalog[candidate[:-1]]
        plural = f"{candidate}s"
        if plural in catalog:
            return catalog[plural]
    for concept in catalog.values():
        if same_topic(concept.title, title):
            return concept
    covered = [concept for concept in catalog.values() if explanation_covers(concept.explanation, title)]
    if not covered:
        return None
    covered.sort(key=lambda concept: (concept.level, len(concept.explanation)))
    broadest = covered[0]
    if proposed_level is not None and proposed_level > broadest.level:
        return None
    return broadest


def _proposed_level(node: dict) -> int | None:
    raw = node.get("level")
    if raw is None or raw == "":
        return None
    try:
        return max(0, int(raw))
    except (TypeError, ValueError):
        return None


def _referenced_concept(node: dict, by_id: dict[UUID, Concept]) -> Concept | None:
    raw = node.get("concept_id")
    if not raw:
        return None
    try:
        concept_id = UUID(str(raw))
    except ValueError:
        return None
    return by_id.get(concept_id)


def _merge_explanation(concept: Concept, node: dict) -> None:
    incoming = str(node.get("explanation") or "").strip()
    if not incoming:
        return
    current = (concept.explanation or "").strip()
    longer = len(incoming) > len(current)
    grew = longer and current.lower() in incoming.lower()
    # A one-line placeholder does not describe the range. A real explanation replaces it.
    if longer and (not current or len(current) < 240 or grew):
        concept.explanation = incoming


def _candidate_edges(branch: dict) -> list[dict]:
    edges = []
    for edge in branch.get("edges") or []:
        if isinstance(edge, dict):
            edges.append(edge)
    return edges


def _consider_edge(
    session: Session,
    graph: Graph,
    edge: dict,
    temp_ids: dict[str, UUID],
    by_id: dict[UUID, Concept],
    seen_edges: set[tuple[UUID, UUID, str]],
    directed: dict[UUID, set[UUID]],
    primary_targets: set[UUID],
    added: list[Edge],
    extend_request_id: UUID | None,
) -> None:
    kind = str(edge.get("type") or "contains")
    if kind not in EDGE_TYPES:
        return
    source = _endpoint(edge.get("from"), temp_ids, by_id)
    target = _endpoint(edge.get("to"), temp_ids, by_id)
    if source is None or target is None or source == target:
        return
    identity = (source, target, kind)
    if identity in seen_edges:
        return
    if kind in DIRECTED_TYPES and creates_cycle(directed, source, target):
        return
    primary = kind == "contains" and target not in primary_targets and bool(edge.get("is_primary_parent", True))
    row = Edge(
        graph_id=graph.id,
        from_concept_id=source,
        to_concept_id=target,
        type=kind,
        is_primary_parent=primary,
        extend_request_id=extend_request_id,
    )
    session.add(row)
    seen_edges.add(identity)
    added.append(row)
    if kind in DIRECTED_TYPES:
        directed.setdefault(source, set()).add(target)
    if primary:
        primary_targets.add(target)


def _endpoint(token: object, temp_ids: dict[str, UUID], by_id: dict[UUID, Concept]) -> UUID | None:
    if token is None:
        return None
    text = str(token)
    if text in temp_ids:
        return temp_ids[text]
    try:
        parsed = UUID(text)
    except ValueError:
        return None
    return parsed if parsed in by_id else None
