from uuid import uuid4

from sqlmodel import select

from app.features.knowledge_graph.domain import ConceptNode, ObjectiveNode, ReleaseSnapshot
from app.features.knowledge_graph.models import Concept
from app.features.knowledge_graph.service import load_snapshot, publish_snapshot, shared_graph
from app.features.knowledge_graph.workspace import workspace_graph
from app.features.mastery.service import add_evidence, concept_rollup


def _node(title: str, summary: str, statement: str) -> ConceptNode:
    return ConceptNode(
        concept_id=uuid4(),
        title=title,
        summary=summary,
        objectives=[ObjectiveNode(objective_id=uuid4(), statement=statement, cognitive_dimension="understanding")],
    )


def test_overlapping_topics_share_a_concept_and_its_evidence(session, user):
    fossil_summary = "Preserved remains used to reconstruct past life."
    fossil_statement = "Explain what a fossil records"
    graph = shared_graph(session)
    first = publish_snapshot(
        session,
        graph_id=graph.id,
        base_release_id=None,
        snapshot=ReleaseSnapshot(
            concepts=[
                _node("Dinosaurs", "Archosaurs.", "Explain what a dinosaur is"),
                _node("Fossil", fossil_summary, fossil_statement),
            ]
        ),
        actor_user_id=user.id,
    )
    session.flush()
    loaded = load_snapshot(session, first.id)
    second = publish_snapshot(
        session,
        graph_id=graph.id,
        base_release_id=first.id,
        snapshot=ReleaseSnapshot(
            concepts=[
                *loaded.concepts,
                _node("Paleontology", "The study of ancient life.", "Explain what paleontology studies"),
                _node("Fossil", fossil_summary, fossil_statement),
            ]
        ),
        actor_user_id=user.id,
    )
    session.flush()
    fossils = list(session.exec(select(Concept).where(Concept.canonical_key == "fossil")).all())
    assert len(fossils) == 1
    dino_fossil = next(concept for concept in load_snapshot(session, first.id).concepts if concept.title == "Fossil")
    paleo_fossil = next(concept for concept in load_snapshot(session, second.id).concepts if concept.title == "Fossil")
    assert dino_fossil.concept_id == paleo_fossil.concept_id == fossils[0].id
    assert dino_fossil.objectives[0].objective_id == paleo_fossil.objectives[0].objective_id

    add_evidence(
        session,
        user_id=user.id,
        objective_id=paleo_fossil.objectives[0].objective_id,
        objective_revision_id=paleo_fossil.objectives[0].revision_id,
        concept_id=paleo_fossil.concept_id,
        concept_revision_id=paleo_fossil.revision_id,
        dimension="understanding",
        score=0.8,
        weight=1,
        method="keyword",
        attempt_id=None,
    )
    rollup = concept_rollup(session, user.id, dino_fossil.concept_id, [dino_fossil.objectives[0].objective_id])
    assert rollup["estimate"] > 0
    payload = workspace_graph(session, user)
    shared = [node for node in payload["nodes"] if node["title"] == "Fossil"]
    assert len(shared) == 1
    assert shared[0]["estimate"] > 0
    assert shared[0]["concept_id"] == str(fossils[0].id)
    assert any(node["title"] == "Dinosaurs" for node in payload["nodes"])
    assert any(node["title"] == "Paleontology" for node in payload["nodes"])
