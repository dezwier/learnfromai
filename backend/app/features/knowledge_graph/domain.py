from __future__ import annotations

import hashlib
import json
from dataclasses import dataclass, field
from uuid import UUID


@dataclass
class ObjectiveNode:
    objective_id: UUID
    statement: str
    cognitive_dimension: str
    success_criteria: dict = field(default_factory=dict)
    revision_id: UUID | None = None
    revision_no: int = 0
    fingerprint: str = ""

    def __post_init__(self) -> None:
        if not self.fingerprint:
            self.fingerprint = fingerprint_text(self.statement)


@dataclass
class ConceptNode:
    concept_id: UUID
    title: str
    summary: str
    knowledge_type: str = "timeless_foundation"
    change_kind: str = "initial"
    source_status: str = "user_custom"
    objectives: list[ObjectiveNode] = field(default_factory=list)
    revision_id: UUID | None = None
    revision_no: int = 0
    semantic_fingerprint: str = ""
    canonical_key: str | None = None

    def __post_init__(self) -> None:
        if not self.semantic_fingerprint:
            self.semantic_fingerprint = fingerprint_text(
                self.title + "\n" + self.summary + "\n" + "|".join(o.fingerprint for o in self.objectives)
            )


@dataclass
class EdgeNode:
    edge_id: UUID
    from_concept_id: UUID
    to_concept_id: UUID
    type: str
    is_primary_parent: bool = False
    revision_id: UUID | None = None
    revision_no: int = 0


@dataclass
class Tombstone:
    concept_id: UUID
    title: str
    summary: str
    revision_id: UUID | None = None
    revision_no: int = 0


@dataclass
class ReleaseSnapshot:
    concepts: list[ConceptNode] = field(default_factory=list)
    edges: list[EdgeNode] = field(default_factory=list)
    tombstones: list[Tombstone] = field(default_factory=list)

    def concept(self, concept_id: UUID) -> ConceptNode | None:
        return next((item for item in self.concepts if item.concept_id == concept_id), None)


def fingerprint_text(value: str) -> str:
    normalized = " ".join(value.lower().split())
    return hashlib.sha256(normalized.encode()).hexdigest()


def release_checksum(concept_revision_ids: list[UUID], edge_revision_ids: list[UUID]) -> str:
    payload = {
        "concepts": sorted(str(item) for item in concept_revision_ids),
        "edges": sorted(str(item) for item in edge_revision_ids),
    }
    raw = json.dumps(payload, separators=(",", ":"), sort_keys=True)
    return hashlib.sha256(raw.encode()).hexdigest()


class GraphValidationError(Exception):
    def __init__(self, reason: str, **details: object) -> None:
        super().__init__(reason)
        self.reason = reason
        self.details = details


def validate_snapshot(
    snapshot: ReleaseSnapshot,
    *,
    max_nodes: int,
    max_depth: int,
    max_fanout: int,
) -> None:
    ids = [concept.concept_id for concept in snapshot.concepts]
    if len(ids) != len(set(ids)):
        raise GraphValidationError("duplicate_concept")
    if len(ids) > max_nodes:
        raise GraphValidationError("node_cap", count=len(ids), max_nodes=max_nodes)
    included = set(ids)
    for concept in snapshot.concepts:
        obj_ids = [item.objective_id for item in concept.objectives]
        if len(obj_ids) != len(set(obj_ids)):
            raise GraphValidationError("duplicate_objective", concept_id=str(concept.concept_id))
        if not concept.title.strip() or not concept.objectives:
            raise GraphValidationError("concept_incomplete", concept_id=str(concept.concept_id))
        for objective in concept.objectives:
            if not objective.statement.strip():
                raise GraphValidationError("objective_incomplete", objective_id=str(objective.objective_id))

    children: dict[UUID, list[UUID]] = {concept_id: [] for concept_id in included}
    prereq: dict[UUID, list[UUID]] = {concept_id: [] for concept_id in included}
    primary_count: dict[UUID, int] = {concept_id: 0 for concept_id in included}
    titles_by_parent: dict[UUID | None, set[str]] = {}

    for edge in snapshot.edges:
        if edge.from_concept_id not in included or edge.to_concept_id not in included:
            raise GraphValidationError(
                "dangling_edge",
                edge_id=str(edge.edge_id),
                type=edge.type,
            )
        if edge.type == "contains":
            children[edge.from_concept_id].append(edge.to_concept_id)
            if edge.is_primary_parent:
                primary_count[edge.to_concept_id] += 1
        elif edge.type == "prerequisite":
            prereq[edge.from_concept_id].append(edge.to_concept_id)
        elif edge.type not in {"related", "supersedes", "part_of"}:
            raise GraphValidationError("unknown_edge", type=edge.type)

    for concept_id, count in primary_count.items():
        if count > 1:
            raise GraphValidationError("multiple_primary_parents", concept_id=str(concept_id))

    for edge in snapshot.edges:
        if edge.type != "contains":
            continue
        parent = edge.from_concept_id if edge.is_primary_parent or primary_count[edge.to_concept_id] == 0 else None
        if parent is None and not edge.is_primary_parent and primary_count[edge.to_concept_id] > 0:
            continue
        key_parent = edge.from_concept_id
        title = snapshot.concept(edge.to_concept_id).title.strip().lower()  # type: ignore[union-attr]
        bucket = titles_by_parent.setdefault(key_parent, set())
        if title in bucket:
            raise GraphValidationError("duplicate_label", parent_id=str(key_parent), title=title)
        bucket.add(title)

    _assert_acyclic(children, "contains_cycle")
    _assert_acyclic(prereq, "prerequisite_cycle")

    for concept_id, kids in children.items():
        if len(kids) > max_fanout:
            raise GraphValidationError("fanout_cap", concept_id=str(concept_id), fanout=len(kids))

    depth = _max_depth(children)
    if depth > max_depth:
        raise GraphValidationError("depth_cap", depth=depth, max_depth=max_depth)


def _assert_acyclic(adjacency: dict[UUID, list[UUID]], reason: str) -> None:
    color: dict[UUID, int] = {}

    def visit(node: UUID, trail: list[UUID]) -> None:
        color[node] = 1
        for nxt in adjacency.get(node, []):
            state = color.get(nxt, 0)
            if state == 1:
                raise GraphValidationError(reason, path=[str(item) for item in trail + [nxt]])
            if state == 0:
                visit(nxt, trail + [nxt])
        color[node] = 2

    for node in adjacency:
        if color.get(node, 0) == 0:
            visit(node, [node])


def _max_depth(children: dict[UUID, list[UUID]]) -> int:
    incoming = {node: 0 for node in children}
    for kids in children.values():
        for kid in kids:
            incoming[kid] = incoming.get(kid, 0) + 1
    roots = [node for node, count in incoming.items() if count == 0] or list(children)
    best = 1 if children else 0

    def walk(node: UUID, depth: int, seen: set[UUID]) -> None:
        nonlocal best
        best = max(best, depth)
        for kid in children.get(node, []):
            if kid in seen:
                continue
            walk(kid, depth + 1, seen | {kid})

    for root in roots:
        walk(root, 1, {root})
    return best


def diff_snapshots(before: ReleaseSnapshot, after: ReleaseSnapshot) -> dict:
    before_map = {item.concept_id: item for item in before.concepts}
    after_map = {item.concept_id: item for item in after.concepts}
    added, removed, revised = [], [], []
    for concept_id, concept in after_map.items():
        prior = before_map.get(concept_id)
        if prior is None:
            added.append({"concept_id": str(concept_id), "title": concept.title})
        elif prior.revision_id != concept.revision_id or prior.semantic_fingerprint != concept.semantic_fingerprint:
            revised.append(
                {
                    "concept_id": str(concept_id),
                    "title": concept.title,
                    "from_revision_id": str(prior.revision_id) if prior.revision_id else None,
                    "to_revision_id": str(concept.revision_id) if concept.revision_id else None,
                }
            )
    for concept_id, concept in before_map.items():
        if concept_id not in after_map:
            removed.append({"concept_id": str(concept_id), "title": concept.title})

    def edge_key(edge: EdgeNode) -> tuple:
        return (edge.edge_id, edge.from_concept_id, edge.to_concept_id, edge.type, edge.is_primary_parent)

    before_edges = {edge.edge_id: edge for edge in before.edges}
    after_edges = {edge.edge_id: edge for edge in after.edges}
    edges_added, edges_removed, reparented = [], [], []
    for edge_id, edge in after_edges.items():
        prior = before_edges.get(edge_id)
        if prior is None:
            edges_added.append(_edge_dict(edge))
        elif edge_key(prior) != edge_key(edge):
            if edge.type == "contains" and (
                prior.from_concept_id != edge.from_concept_id or prior.is_primary_parent != edge.is_primary_parent
            ):
                reparented.append({"edge_id": str(edge_id), "concept_id": str(edge.to_concept_id), **_edge_dict(edge)})
            else:
                edges_added.append(_edge_dict(edge))
                edges_removed.append(_edge_dict(prior))
    for edge_id, edge in before_edges.items():
        if edge_id not in after_edges:
            edges_removed.append(_edge_dict(edge))
    return {
        "concepts_added": added,
        "concepts_removed": removed,
        "concepts_revised": revised,
        "edges_added": edges_added,
        "edges_removed": edges_removed,
        "reparented": reparented,
    }


def _edge_dict(edge: EdgeNode) -> dict:
    return {
        "edge_id": str(edge.edge_id),
        "from_concept_id": str(edge.from_concept_id),
        "to_concept_id": str(edge.to_concept_id),
        "type": edge.type,
        "is_primary_parent": edge.is_primary_parent,
    }
