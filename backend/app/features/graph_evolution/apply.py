from __future__ import annotations

from dataclasses import replace
from uuid import UUID, uuid4

from app.features.knowledge_graph.domain import (
    ConceptNode,
    EdgeNode,
    ObjectiveNode,
    ReleaseSnapshot,
    Tombstone,
)


def clone_snapshot(snapshot: ReleaseSnapshot) -> ReleaseSnapshot:
    concepts = []
    for concept in snapshot.concepts:
        objectives = [
            ObjectiveNode(
                objective_id=item.objective_id,
                statement=item.statement,
                cognitive_dimension=item.cognitive_dimension,
                success_criteria=dict(item.success_criteria),
                revision_id=item.revision_id,
                revision_no=item.revision_no,
                fingerprint=item.fingerprint,
            )
            for item in concept.objectives
        ]
        concepts.append(
            ConceptNode(
                concept_id=concept.concept_id,
                title=concept.title,
                summary=concept.summary,
                knowledge_type=concept.knowledge_type,
                change_kind=concept.change_kind,
                source_status=concept.source_status,
                objectives=objectives,
                revision_id=concept.revision_id,
                revision_no=concept.revision_no,
                semantic_fingerprint=concept.semantic_fingerprint,
                canonical_key=concept.canonical_key,
            )
        )
    edges = [
        EdgeNode(
            edge_id=edge.edge_id,
            from_concept_id=edge.from_concept_id,
            to_concept_id=edge.to_concept_id,
            type=edge.type,
            is_primary_parent=edge.is_primary_parent,
            revision_id=edge.revision_id,
            revision_no=edge.revision_no,
        )
        for edge in snapshot.edges
    ]
    return ReleaseSnapshot(concepts=concepts, edges=edges, tombstones=list(snapshot.tombstones))


def apply_operations(snapshot: ReleaseSnapshot, operations: list[dict]) -> tuple[ReleaseSnapshot, dict[str, UUID]]:
    """Apply a proposal. Temp ids in the operations become server UUIDs. The input snapshot is copied."""
    working = clone_snapshot(snapshot)
    temp_ids: dict[str, UUID] = {}
    for operation in operations:
        kind = operation["op"]
        if kind == "add_concept":
            _add_concept(working, operation, temp_ids)
        elif kind == "add_edge":
            _add_edge(working, operation, temp_ids)
        elif kind == "revise_concept":
            _revise_concept(working, operation)
        elif kind == "reparent":
            _reparent(working, operation, temp_ids)
        elif kind == "remove_concept":
            _remove_concept(working, operation, temp_ids)
        else:
            raise ValueError(f"unsupported operation {kind}")
    return working, temp_ids


def resolve_ref(value: str, temp_ids: dict[str, UUID]) -> UUID:
    if value in temp_ids:
        return temp_ids[value]
    return UUID(value)


def _add_concept(snapshot: ReleaseSnapshot, operation: dict, temp_ids: dict[str, UUID]) -> None:
    concept_id = uuid4()
    temp_ids[operation["temp_id"]] = concept_id
    objectives = []
    for item in operation.get("objectives") or []:
        objective_id = UUID(str(item["objective_id"])) if item.get("objective_id") else uuid4()
        temp_ids[item["temp_id"]] = objective_id
        objectives.append(
            ObjectiveNode(
                objective_id=objective_id,
                statement=item["statement"],
                cognitive_dimension=item.get("cognitive_dimension") or "understanding",
                success_criteria=item.get("success_criteria") or {},
            )
        )
    from app.features.knowledge_graph.identity import canonical_key_for

    snapshot.concepts.append(
        ConceptNode(
            concept_id=concept_id,
            title=operation["title"],
            summary=operation.get("summary") or "",
            knowledge_type=operation.get("knowledge_type") or "timeless_foundation",
            change_kind="initial",
            source_status=operation.get("source_status") or "source_pending",
            objectives=objectives,
            canonical_key=operation.get("canonical_key") or canonical_key_for(operation["title"]),
        )
    )
    parent = operation.get("parent")
    if parent:
        snapshot.edges.append(
            EdgeNode(
                edge_id=uuid4(),
                from_concept_id=resolve_ref(str(parent), temp_ids),
                to_concept_id=concept_id,
                type="contains",
                is_primary_parent=True,
            )
        )


def _add_edge(snapshot: ReleaseSnapshot, operation: dict, temp_ids: dict[str, UUID]) -> None:
    snapshot.edges.append(
        EdgeNode(
            edge_id=uuid4(),
            from_concept_id=resolve_ref(str(operation["from"]), temp_ids),
            to_concept_id=resolve_ref(str(operation["to"]), temp_ids),
            type=operation["type"],
            is_primary_parent=bool(operation.get("is_primary_parent")),
        )
    )


def _revise_concept(snapshot: ReleaseSnapshot, operation: dict) -> None:
    concept = snapshot.concept(UUID(str(operation["concept_id"])))
    if concept is None:
        raise ValueError("revise_concept target missing")
    if "title" in operation:
        concept.title = operation["title"]
    if "summary" in operation:
        concept.summary = operation["summary"]
    concept.change_kind = operation.get("change_kind") or "semantic"
    concept.source_status = operation.get("source_status") or concept.source_status
    concept.revision_id = None
    concept.semantic_fingerprint = ""
    for item in operation.get("objectives") or []:
        if item.get("objective_id"):
            objective = next(obj for obj in concept.objectives if obj.objective_id == UUID(str(item["objective_id"])))
            objective.statement = item["statement"]
            objective.fingerprint = ""
            objective.revision_id = None
            if item.get("cognitive_dimension"):
                objective.cognitive_dimension = item["cognitive_dimension"]
            objective.__post_init__()
        else:
            concept.objectives.append(
                ObjectiveNode(
                    objective_id=uuid4(),
                    statement=item["statement"],
                    cognitive_dimension=item.get("cognitive_dimension") or "understanding",
                )
            )
    concept.semantic_fingerprint = ""
    concept.__post_init__()


def _reparent(snapshot: ReleaseSnapshot, operation: dict, temp_ids: dict[str, UUID]) -> None:
    concept_id = resolve_ref(str(operation["concept_id"]), temp_ids)
    parent_id = resolve_ref(str(operation["parent_concept_id"]), temp_ids)
    moved = False
    for edge in snapshot.edges:
        if edge.type == "contains" and edge.to_concept_id == concept_id and edge.is_primary_parent:
            edge.from_concept_id = parent_id
            edge.revision_id = None
            moved = True
    if not moved:
        snapshot.edges.append(EdgeNode(uuid4(), parent_id, concept_id, "contains", True))


def _remove_concept(snapshot: ReleaseSnapshot, operation: dict, temp_ids: dict[str, UUID]) -> None:
    concept_id = resolve_ref(str(operation["concept_id"]), temp_ids)
    concept = snapshot.concept(concept_id)
    if concept is None:
        return
    snapshot.tombstones.append(Tombstone(concept_id, concept.title, concept.summary))
    snapshot.concepts = [item for item in snapshot.concepts if item.concept_id != concept_id]
    snapshot.edges = [
        edge for edge in snapshot.edges if edge.from_concept_id != concept_id and edge.to_concept_id != concept_id
    ]


def objective_refs(snapshot: ReleaseSnapshot):
    from app.features.graph_evolution.policies import ObjectiveRef

    refs = []
    for concept in snapshot.concepts:
        for objective in concept.objectives:
            refs.append(
                ObjectiveRef(objective.objective_id, concept.concept_id, objective.fingerprint, objective.statement)
            )
    return refs


def mark_changed(concept: ConceptNode) -> None:
    concept.revision_id = None
    concept.semantic_fingerprint = ""
    concept.__post_init__()
    _ = replace(concept)
