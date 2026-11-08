from __future__ import annotations

from uuid import UUID

from app.features.knowledge_graph.models import Concept, Edge


def assign_levels(concepts: list[Concept], edges: list[Edge]) -> None:
    """Set each node's level from the contains tree. A root domain is level 1."""
    ids = [concept.id for concept in concepts]
    children: dict[UUID, list[UUID]] = {concept_id: [] for concept_id in ids}
    incoming = {concept_id: 0 for concept_id in ids}
    for edge in edges:
        if edge.type != "contains":
            continue
        if edge.from_concept_id not in incoming or edge.to_concept_id not in incoming:
            continue
        children[edge.from_concept_id].append(edge.to_concept_id)
        incoming[edge.to_concept_id] += 1
    unreachable = len(ids) + 1
    level = {concept_id: 1 if incoming[concept_id] == 0 else unreachable for concept_id in ids}
    changed = True
    guard = 0
    while changed and guard <= len(ids):
        changed = False
        guard += 1
        for parent, kids in children.items():
            if level[parent] >= unreachable:
                continue
            for child in kids:
                candidate = level[parent] + 1
                if candidate < level[child]:
                    level[child] = candidate
                    changed = True
    for concept in concepts:
        value = level[concept.id]
        concept.level = 1 if value >= unreachable else value
