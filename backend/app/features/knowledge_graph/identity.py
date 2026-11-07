from __future__ import annotations

from uuid import UUID

from sqlmodel import Session, select

from app.features.knowledge_graph.domain import ConceptNode, ReleaseSnapshot
from app.features.knowledge_graph.models import Concept, ConceptRevision, ObjectiveRevision


def canonical_key_for(title: str) -> str:
    cleaned = "".join(char.lower() if char.isalnum() else "-" for char in title.strip())
    while "--" in cleaned:
        cleaned = cleaned.replace("--", "-")
    return cleaned.strip("-") or "topic"


def is_placeholder_title(title: str, titles: set[str] | None = None) -> bool:
    """Fixture labels such as 'Topic structure' are not subjects."""
    folded = title.strip().lower()
    if folded in {"topic", "topic structure", "topic origins"}:
        return True
    known = {item.strip().lower() for item in titles} if titles is not None else None
    for suffix in (" structure", " origins"):
        if not folded.endswith(suffix):
            continue
        stem = folded[: -len(suffix)].strip()
        if known is None or stem in known:
            return True
    return False


def same_topic(left: str, right: str) -> bool:
    """True when two titles name the same node, including a trailing plural."""
    a = canonical_key_for(left)
    b = canonical_key_for(right)
    if a == b:
        return True
    return (a.endswith("s") and a[:-1] == b) or (b.endswith("s") and b[:-1] == a)


def neighborhood(session: Session, limit: int = 200) -> list[dict]:
    """Titles the generator can point at instead of inventing a second copy."""
    rows = session.exec(select(Concept).where(Concept.canonical_key.is_not(None)).limit(limit)).all()  # type: ignore[union-attr]
    payload = []
    for concept in rows:
        if not concept.canonical_key:
            continue
        revision = _latest_revision(session, concept.id)
        payload.append(
            {
                "concept_id": str(concept.id),
                "title": revision.title if revision else concept.canonical_key,
                "canonical_key": concept.canonical_key,
            }
        )
    return payload


def bind_existing_identities(session: Session, snapshot: ReleaseSnapshot) -> ReleaseSnapshot:
    """Reuse a concept and its objectives when the title key already exists.

    A dinosaurs graph and a paleontology graph that both name Fossil keep one
    concept id, so evidence earned in either place is the same progress.
    """
    catalog = _catalog(session)
    id_map: dict[UUID, UUID] = {}
    for concept in snapshot.concepts:
        key = concept.canonical_key or canonical_key_for(concept.title)
        concept.canonical_key = key
        found = catalog.get(key)
        if found is None:
            catalog[key] = (concept.concept_id, _local_objectives(concept), None)
            continue
        existing_id, objectives, revision = found
        if existing_id != concept.concept_id:
            id_map[concept.concept_id] = existing_id
            concept.concept_id = existing_id
        _reuse_objectives(concept, objectives, revision)
        _dedupe_objectives(concept)
    if id_map:
        _collapse(snapshot, id_map)
    return snapshot


def _catalog(session: Session) -> dict[str, tuple[UUID, dict[str, tuple[UUID, UUID]], ConceptRevision | None]]:
    catalog: dict[str, tuple[UUID, dict[str, tuple[UUID, UUID]], ConceptRevision | None]] = {}
    rows = session.exec(select(Concept).where(Concept.canonical_key.is_not(None))).all()  # type: ignore[union-attr]
    for concept in rows:
        if not concept.canonical_key or concept.canonical_key in catalog:
            continue
        revision = _latest_revision(session, concept.id)
        objectives: dict[str, tuple[UUID, UUID]] = {}
        if revision is not None:
            objective_rows = session.exec(
                select(ObjectiveRevision).where(ObjectiveRevision.concept_revision_id == revision.id)
            ).all()
            for row in objective_rows:
                objectives[row.semantic_fingerprint] = (row.objective_id, row.id)
        catalog[concept.canonical_key] = (concept.id, objectives, revision)
    return catalog


def _latest_revision(session: Session, concept_id: UUID) -> ConceptRevision | None:
    return session.exec(
        select(ConceptRevision)
        .where(ConceptRevision.concept_id == concept_id, ConceptRevision.status != "deprecated")
        .order_by(ConceptRevision.revision_no.desc())
    ).first()


def _local_objectives(concept: ConceptNode) -> dict[str, tuple[UUID, UUID]]:
    payload: dict[str, tuple[UUID, UUID]] = {}
    for objective in concept.objectives:
        revision_id = objective.revision_id or objective.objective_id
        payload[objective.fingerprint] = (objective.objective_id, revision_id)
    return payload


def _reuse_objectives(concept: ConceptNode, objectives: dict[str, tuple[UUID, UUID]], revision: ConceptRevision | None) -> None:
    matched = True
    for objective in concept.objectives:
        found = objectives.get(objective.fingerprint)
        if found is None:
            matched = False
            continue
        objective.objective_id = found[0]
    if (
        matched
        and revision is not None
        and revision.title == concept.title
        and revision.summary == concept.summary
    ):
        concept.revision_id = revision.id
        concept.revision_no = revision.revision_no
        concept.semantic_fingerprint = revision.semantic_fingerprint
        for objective in concept.objectives:
            found = objectives.get(objective.fingerprint)
            if found is not None:
                objective.revision_id = found[1]


def _dedupe_objectives(concept: ConceptNode) -> None:
    kept = []
    seen: set[UUID] = set()
    for objective in concept.objectives:
        if objective.objective_id in seen:
            continue
        seen.add(objective.objective_id)
        kept.append(objective)
    concept.objectives = kept


def _collapse(snapshot: ReleaseSnapshot, id_map: dict[UUID, UUID]) -> None:
    seen: dict[UUID, ConceptNode] = {}
    concepts: list[ConceptNode] = []
    for concept in snapshot.concepts:
        host = seen.get(concept.concept_id)
        if host is None:
            seen[concept.concept_id] = concept
            concepts.append(concept)
            continue
        have = {objective.objective_id for objective in host.objectives}
        for objective in concept.objectives:
            if objective.objective_id not in have:
                host.objectives.append(objective)
                have.add(objective.objective_id)
    snapshot.concepts = concepts
    edges = []
    seen_edges: set[tuple[UUID, UUID, str]] = set()
    for edge in snapshot.edges:
        edge.from_concept_id = id_map.get(edge.from_concept_id, edge.from_concept_id)
        edge.to_concept_id = id_map.get(edge.to_concept_id, edge.to_concept_id)
        if edge.from_concept_id == edge.to_concept_id:
            continue
        signature = (edge.from_concept_id, edge.to_concept_id, edge.type)
        if signature in seen_edges:
            continue
        seen_edges.add(signature)
        edges.append(edge)
    snapshot.edges = edges
    for tombstone in snapshot.tombstones:
        tombstone.concept_id = id_map.get(tombstone.concept_id, tombstone.concept_id)
