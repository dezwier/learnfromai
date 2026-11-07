from __future__ import annotations

import hashlib
from uuid import UUID, uuid5

from sqlmodel import Session, select

from app.core.config import get_settings
from app.core.errors import forbidden, graph_stale, invalid_graph, not_found
from app.core.time import utcnow
from app.features.accounts.models import User
from app.features.knowledge_graph.domain import (
    ConceptNode,
    EdgeNode,
    GraphValidationError,
    ObjectiveNode,
    ReleaseSnapshot,
    Tombstone,
    diff_snapshots,
    release_checksum,
    validate_snapshot,
)
from app.features.knowledge_graph.models import (
    Concept,
    ConceptRevision,
    Edge,
    EdgeRevision,
    Graph,
    GraphOverlay,
    GraphRelease,
    LearningObjective,
    ObjectiveRevision,
    ReleaseConcept,
    ReleaseEdge,
    SourceClaim,
    SourceDocument,
)
from app.features.platform.audit import write_audit

SEED_NAMESPACE = UUID("6f0b3c1e-8a1e-4c1a-9f4a-0b5e1d2c3a40")


def stable_id(name: str) -> UUID:
    return uuid5(SEED_NAMESPACE, name)


def limits_from_settings() -> dict[str, int]:
    settings = get_settings()
    return {
        "max_nodes": settings.graph_expansion_max_nodes,
        "max_depth": settings.graph_expansion_max_depth,
        "max_fanout": settings.graph_max_fanout,
    }


def get_graph(session: Session, graph_id: UUID) -> Graph:
    graph = session.get(Graph, graph_id)
    if graph is None:
        raise not_found("Graph not found")
    return graph


def assert_can_read(graph: Graph, user: User) -> None:
    if graph.visibility == "shared" or graph.owner_user_id == user.id:
        return
    raise forbidden("Not your graph")


def assert_can_edit(graph: Graph, user: User) -> None:
    if graph.owner_user_id == user.id or user.is_admin:
        return
    if graph.owner_user_id is None and user.is_admin:
        return
    raise forbidden("You cannot edit this graph")


def publish_snapshot(
    session: Session,
    *,
    graph_id: UUID,
    base_release_id: UUID | None,
    snapshot: ReleaseSnapshot,
    actor_user_id: UUID | None,
    overlay_id: UUID | None = None,
    proposal_id: UUID | None = None,
    limits: dict[str, int] | None = None,
) -> GraphRelease:
    from app.features.knowledge_graph.identity import bind_existing_identities

    snapshot = bind_existing_identities(session, snapshot)
    bounds = limits or limits_from_settings()
    try:
        validate_snapshot(snapshot, **bounds)
    except GraphValidationError as exc:
        raise invalid_graph(exc.reason, **exc.details) from exc

    graph = session.exec(select(Graph).where(Graph.id == graph_id).with_for_update()).one()
    overlay = None
    if overlay_id is not None:
        overlay = session.exec(select(GraphOverlay).where(GraphOverlay.id == overlay_id).with_for_update()).one()
        pointer = overlay.active_private_release_id or overlay.base_release_id
        if base_release_id != pointer and not (
            overlay.active_private_release_id is None and base_release_id == overlay.base_release_id
        ):
            raise graph_stale(str(pointer))
    elif graph.active_release_id != base_release_id:
        raise graph_stale(str(graph.active_release_id) if graph.active_release_id else "")

    version = _next_version(session, graph_id, overlay_id)
    concept_revision_ids: list[UUID] = []
    for concept in snapshot.concepts:
        _ensure_concept(session, graph_id, concept)
        revision = _ensure_concept_revision(session, concept, actor="user" if actor_user_id else "system")
        concept.revision_id = revision.id
        concept_revision_ids.append(revision.id)
        for objective in concept.objectives:
            _ensure_objective(session, concept.concept_id, objective)
            objective_revision = _ensure_objective_revision(session, objective, revision.id)
            objective.revision_id = objective_revision.id
    for tombstone in snapshot.tombstones:
        _write_tombstone(session, tombstone)
    edge_revision_ids: list[UUID] = []
    for edge in snapshot.edges:
        _ensure_edge(session, graph_id, edge)
        edge_revision = _ensure_edge_revision(session, edge)
        edge.revision_id = edge_revision.id
        edge_revision_ids.append(edge_revision.id)

    release = GraphRelease(
        graph_id=graph_id,
        version=version,
        parent_release_id=base_release_id,
        overlay_id=overlay_id,
        checksum=release_checksum(concept_revision_ids, edge_revision_ids),
        status="published",
        published_at=utcnow(),
        published_by=actor_user_id,
        change_proposal_id=proposal_id,
    )
    session.add(release)
    session.flush()
    for concept in snapshot.concepts:
        session.add(
            ReleaseConcept(
                release_id=release.id,
                concept_id=concept.concept_id,
                concept_revision_id=concept.revision_id,  # type: ignore[arg-type]
            )
        )
    for edge in snapshot.edges:
        session.add(
            ReleaseEdge(
                release_id=release.id,
                edge_id=edge.edge_id,
                edge_revision_id=edge.revision_id,  # type: ignore[arg-type]
            )
        )
    if overlay is not None:
        overlay.active_private_release_id = release.id
    else:
        graph.active_release_id = release.id
    write_audit(
        session,
        actor=str(actor_user_id or "system"),
        action="graph.publish",
        entity_type="graph_release",
        entity_id=str(release.id),
        after={"graph_id": str(graph_id), "version": version, "checksum": release.checksum, "overlay_id": str(overlay_id) if overlay_id else None},
    )
    session.flush()
    return release


def load_snapshot(session: Session, release_id: UUID) -> ReleaseSnapshot:
    release = session.get(GraphRelease, release_id)
    if release is None:
        raise not_found("Release not found")
    concepts: list[ConceptNode] = []
    membership = session.exec(select(ReleaseConcept).where(ReleaseConcept.release_id == release_id)).all()
    for row in membership:
        revision = session.get(ConceptRevision, row.concept_revision_id)
        concept = session.get(Concept, row.concept_id)
        if revision is None or concept is None:
            continue
        objectives = []
        objective_rows = session.exec(
            select(ObjectiveRevision).where(ObjectiveRevision.concept_revision_id == revision.id)
        ).all()
        for objective_revision in objective_rows:
            objectives.append(
                ObjectiveNode(
                    objective_id=objective_revision.objective_id,
                    statement=objective_revision.statement,
                    cognitive_dimension=objective_revision.cognitive_dimension,
                    success_criteria=objective_revision.success_criteria,
                    revision_id=objective_revision.id,
                    revision_no=objective_revision.revision_no,
                    fingerprint=objective_revision.semantic_fingerprint,
                )
            )
        concepts.append(
            ConceptNode(
                concept_id=concept.id,
                title=revision.title,
                summary=revision.summary,
                knowledge_type=revision.knowledge_type,
                change_kind=revision.change_kind,
                source_status=revision.source_status,
                objectives=objectives,
                revision_id=revision.id,
                revision_no=revision.revision_no,
                semantic_fingerprint=revision.semantic_fingerprint,
                canonical_key=concept.canonical_key,
            )
        )
    edges: list[EdgeNode] = []
    edge_rows = session.exec(select(ReleaseEdge).where(ReleaseEdge.release_id == release_id)).all()
    for row in edge_rows:
        revision = session.get(EdgeRevision, row.edge_revision_id)
        if revision is None:
            continue
        edges.append(
            EdgeNode(
                edge_id=revision.edge_id,
                from_concept_id=revision.from_concept_id,
                to_concept_id=revision.to_concept_id,
                type=revision.type,
                is_primary_parent=revision.is_primary_parent,
                revision_id=revision.id,
                revision_no=revision.revision_no,
            )
        )
    return ReleaseSnapshot(concepts=concepts, edges=edges)


def build_tree(snapshot: ReleaseSnapshot, mastery: dict[UUID, str] | None = None) -> list[dict]:
    mastery = mastery or {}
    children: dict[UUID, list[UUID]] = {concept.concept_id: [] for concept in snapshot.concepts}
    incoming = {concept.concept_id: 0 for concept in snapshot.concepts}
    prereq_from: dict[UUID, list[UUID]] = {concept.concept_id: [] for concept in snapshot.concepts}
    by_id = {concept.concept_id: concept for concept in snapshot.concepts}
    for edge in snapshot.edges:
        if edge.type == "contains" and edge.to_concept_id in children and edge.from_concept_id in children:
            children[edge.from_concept_id].append(edge.to_concept_id)
            incoming[edge.to_concept_id] += 1
        if edge.type == "prerequisite" and edge.to_concept_id in prereq_from:
            prereq_from[edge.to_concept_id].append(edge.from_concept_id)

    def node(concept_id: UUID) -> dict:
        concept = by_id[concept_id]
        return {
            "concept_id": str(concept.concept_id),
            "revision_id": str(concept.revision_id),
            "title": concept.title,
            "summary": concept.summary,
            "knowledge_type": concept.knowledge_type,
            "source_status": concept.source_status,
            "mastery_status": mastery.get(concept_id, "unknown"),
            "objectives": [
                {
                    "id": str(item.objective_id),
                    "revision_id": str(item.revision_id),
                    "statement": item.statement,
                    "cognitive_dimension": item.cognitive_dimension,
                }
                for item in concept.objectives
            ],
            "prerequisites": [
                {"concept_id": str(source), "title": by_id[source].title}
                for source in prereq_from[concept_id]
                if source in by_id
            ],
            "children": [node(child) for child in children[concept_id]],
        }

    roots = [concept_id for concept_id, count in incoming.items() if count == 0]
    return [node(concept_id) for concept_id in roots]


def concept_detail(snapshot: ReleaseSnapshot, concept_id: UUID) -> dict:
    concept = snapshot.concept(concept_id)
    if concept is None:
        raise not_found("Concept is not in this release")
    related = []
    for edge in snapshot.edges:
        if edge.from_concept_id == concept_id or edge.to_concept_id == concept_id:
            other = edge.to_concept_id if edge.from_concept_id == concept_id else edge.from_concept_id
            other_node = snapshot.concept(other)
            related.append(
                {
                    "edge_id": str(edge.edge_id),
                    "type": edge.type,
                    "direction": "out" if edge.from_concept_id == concept_id else "in",
                    "is_primary_parent": edge.is_primary_parent,
                    "other_concept_id": str(other),
                    "other_title": other_node.title if other_node else "",
                }
            )
    return {
        "concept_id": str(concept.concept_id),
        "revision_id": str(concept.revision_id),
        "title": concept.title,
        "summary": concept.summary,
        "knowledge_type": concept.knowledge_type,
        "source_status": concept.source_status,
        "change_kind": concept.change_kind,
        "objectives": [
            {
                "id": str(item.objective_id),
                "revision_id": str(item.revision_id),
                "statement": item.statement,
                "cognitive_dimension": item.cognitive_dimension,
                "success_criteria": item.success_criteria,
            }
            for item in concept.objectives
        ],
        "edges": related,
    }


def release_diff(session: Session, from_id: UUID, to_id: UUID) -> dict:
    payload = diff_snapshots(load_snapshot(session, from_id), load_snapshot(session, to_id))
    payload["from_release_id"] = str(from_id)
    payload["to_release_id"] = str(to_id)
    return payload


def list_releases(session: Session, graph_id: UUID) -> list[GraphRelease]:
    return list(
        session.exec(select(GraphRelease).where(GraphRelease.graph_id == graph_id).order_by(GraphRelease.version)).all()
    )


def shared_graph(session: Session) -> Graph:
    """The one graph everyone extends. Topics add nodes here instead of starting a private copy."""
    existing = session.exec(select(Graph).where(Graph.slug == "knowledge")).first()
    if existing is not None:
        return existing
    graph = Graph(slug="knowledge", title="Knowledge", visibility="shared", owner_user_id=None)
    session.add(graph)
    session.flush()
    return graph


def find_graph_for_topic(session: Session, topic: str) -> Graph | None:
    slug = slugify(topic)
    match = session.exec(select(Graph).where(Graph.slug == slug)).first()
    if match:
        return match
    return session.exec(select(Graph).where(Graph.title.ilike(topic.strip()))).first()  # type: ignore[attr-defined]


def slugify(value: str) -> str:
    cleaned = "".join(char.lower() if char.isalnum() else "-" for char in value.strip())
    while "--" in cleaned:
        cleaned = cleaned.replace("--", "-")
    return cleaned.strip("-") or "topic"


def seed_decision_trees(session: Session) -> Graph:
    existing = session.exec(select(Graph).where(Graph.slug == "decision-trees")).first()
    if existing and existing.active_release_id:
        return existing
    graph = existing or Graph(
        id=stable_id("graph:decision-trees"),
        slug="decision-trees",
        title="Decision Trees",
        visibility="shared",
        owner_user_id=None,
    )
    if existing is None:
        session.add(graph)
        session.flush()
    dt, split, entropy, gain = (
        stable_id("concept:decision-trees"),
        stable_id("concept:splitting"),
        stable_id("concept:entropy"),
        stable_id("concept:information-gain"),
    )
    snapshot = ReleaseSnapshot(
        concepts=[
            _seed_concept(dt, "decision-trees", "Decision Trees", "Recursive partitions of a feature space.", "explain a decision tree as a recursive partition", "understanding"),
            _seed_concept(split, "splitting-criteria", "Splitting Criteria", "How a tree chooses a split.", "choose a split that reduces impurity", "application"),
            _seed_concept(entropy, "entropy", "Entropy", "Uncertainty of a class distribution.", "calculate entropy from class frequencies", "application"),
            _seed_concept(gain, "information-gain", "Information Gain", "Impurity reduction from a candidate split.", "compute information gain of a candidate split", "application"),
        ],
        edges=[
            EdgeNode(stable_id("edge:dt-split"), dt, split, "contains", True),
            EdgeNode(stable_id("edge:split-entropy"), split, entropy, "contains", True),
            EdgeNode(stable_id("edge:split-gain"), split, gain, "contains", True),
            EdgeNode(stable_id("edge:entropy-prereq-gain"), entropy, gain, "prerequisite", False),
        ],
    )
    publish_snapshot(
        session,
        graph_id=graph.id,
        base_release_id=None,
        snapshot=snapshot,
        actor_user_id=None,
    )
    source = SourceDocument(
        id=stable_id("source:dt-wiki"),
        source_url="https://en.wikipedia.org/wiki/Decision_tree_learning",
        title="Decision tree learning",
        publisher="Wikipedia",
        content_hash=hashlib.sha256(b"decision-tree-learning-fixture").hexdigest(),
        trust_tier="source_pending",
        license="CC BY-SA",
    )
    session.add(source)
    session.flush()
    for concept in snapshot.concepts:
        session.add(
            SourceClaim(
                source_id=source.id,
                concept_revision_id=concept.revision_id,  # type: ignore[arg-type]
                claim_key=concept.canonical_key or concept.title,
                support_status="source_pending",
            )
        )
    session.flush()
    return graph


def _seed_concept(concept_id: UUID, key: str, title: str, summary: str, statement: str, dimension: str) -> ConceptNode:
    return ConceptNode(
        concept_id=concept_id,
        canonical_key=key,
        title=title,
        summary=summary,
        knowledge_type="timeless_foundation",
        change_kind="initial",
        source_status="source_pending",
        objectives=[
            ObjectiveNode(
                objective_id=stable_id(f"objective:{key}"),
                statement=statement,
                cognitive_dimension=dimension,
                success_criteria={"mode": "keyword"},
            )
        ],
    )


def _next_version(session: Session, graph_id: UUID, overlay_id: UUID | None) -> int:
    query = select(GraphRelease.version).where(GraphRelease.graph_id == graph_id)
    if overlay_id is None:
        query = query.where(GraphRelease.overlay_id.is_(None))  # type: ignore[union-attr]
    else:
        query = query.where(GraphRelease.overlay_id == overlay_id)
    versions = list(session.exec(query).all())
    return (max(versions) if versions else 0) + 1


def _ensure_concept(session: Session, graph_id: UUID, concept: ConceptNode) -> None:
    if session.get(Concept, concept.concept_id) is None:
        session.add(
            Concept(
                id=concept.concept_id,
                canonical_key=concept.canonical_key,
                origin_graph_id=graph_id,
            )
        )
        session.flush()


def _ensure_concept_revision(session: Session, concept: ConceptNode, actor: str) -> ConceptRevision:
    if concept.revision_id is not None:
        found = session.get(ConceptRevision, concept.revision_id)
        if found is not None:
            return found
    number = _next_revision_no(session, ConceptRevision, ConceptRevision.concept_id, concept.concept_id)
    revision = ConceptRevision(
        concept_id=concept.concept_id,
        revision_no=number,
        title=concept.title,
        summary=concept.summary,
        knowledge_type=concept.knowledge_type,
        semantic_fingerprint=concept.semantic_fingerprint,
        change_kind=concept.change_kind,
        source_status=concept.source_status,
        status="published",
        creator=actor,
    )
    session.add(revision)
    session.flush()
    return revision


def _ensure_objective(session: Session, concept_id: UUID, objective: ObjectiveNode) -> None:
    if session.get(LearningObjective, objective.objective_id) is None:
        session.add(LearningObjective(id=objective.objective_id, origin_concept_id=concept_id, status="active"))
        session.flush()


def _ensure_objective_revision(session: Session, objective: ObjectiveNode, concept_revision_id: UUID) -> ObjectiveRevision:
    if objective.revision_id is not None:
        found = session.get(ObjectiveRevision, objective.revision_id)
        if found is not None:
            return found
    number = _next_revision_no(session, ObjectiveRevision, ObjectiveRevision.objective_id, objective.objective_id)
    revision = ObjectiveRevision(
        objective_id=objective.objective_id,
        concept_revision_id=concept_revision_id,
        revision_no=number,
        statement=objective.statement,
        success_criteria=objective.success_criteria,
        cognitive_dimension=objective.cognitive_dimension,
        semantic_fingerprint=objective.fingerprint,
    )
    session.add(revision)
    session.flush()
    return revision


def _ensure_edge(session: Session, graph_id: UUID, edge: EdgeNode) -> None:
    if session.get(Edge, edge.edge_id) is None:
        session.add(Edge(id=edge.edge_id, graph_id=graph_id))
        session.flush()


def _ensure_edge_revision(session: Session, edge: EdgeNode) -> EdgeRevision:
    if edge.revision_id is not None:
        found = session.get(EdgeRevision, edge.revision_id)
        if found is not None:
            return found
    number = _next_revision_no(session, EdgeRevision, EdgeRevision.edge_id, edge.edge_id)
    revision = EdgeRevision(
        edge_id=edge.edge_id,
        revision_no=number,
        from_concept_id=edge.from_concept_id,
        to_concept_id=edge.to_concept_id,
        type=edge.type,
        is_primary_parent=edge.is_primary_parent,
    )
    session.add(revision)
    session.flush()
    return revision


def _write_tombstone(session: Session, tombstone: Tombstone) -> None:
    concept = session.get(Concept, tombstone.concept_id)
    if concept is None:
        return
    number = _next_revision_no(session, ConceptRevision, ConceptRevision.concept_id, tombstone.concept_id)
    session.add(
        ConceptRevision(
            concept_id=tombstone.concept_id,
            revision_no=number,
            title=tombstone.title,
            summary=tombstone.summary,
            knowledge_type="timeless_foundation",
            semantic_fingerprint=tombstone.title,
            change_kind="deprecate",
            source_status="user_custom",
            status="deprecated",
            creator="system",
        )
    )
    session.flush()


def _next_revision_no(session: Session, model, column, owner_id: UUID) -> int:
    numbers = list(session.exec(select(model.revision_no).where(column == owner_id)).all())
    return (max(numbers) if numbers else 0) + 1
