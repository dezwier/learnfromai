from sqlmodel import select

from app.features.graph_extend.service import apply_branch
from app.features.knowledge_graph.models import Concept, Edge
from app.features.knowledge_graph.service import shared_graph


def test_loose_parenting_nodes_become_one_tree_under_life_skills(session):
    graph = shared_graph(session)
    session.commit()
    apply_branch(
        session,
        graph=graph,
        parent_concept_id=None,
        instruction="parenting",
        branch={
            "nodes": [
                {"temp_id": "styles", "title": "Parenting styles", "summary": "Ways of raising children", "explanation": "Covers parenting styles."},
                {"temp_id": "discipline", "title": "Discipline", "summary": "Limits", "explanation": "Covers discipline of children."},
                {"temp_id": "attachment", "title": "Attachment", "summary": "Bonds", "explanation": "Covers attachment between parent and child."},
            ],
            "edges": [],
        },
    )
    session.commit()
    stored = {concept.title: concept for concept in session.exec(select(Concept).where(Concept.origin_graph_id == graph.id)).all()}
    assert set(stored) == {"Life skills", "Parenting", "Parenting styles", "Discipline", "Attachment"}
    assert stored["Life skills"].level == 1
    assert stored["Parenting"].level == 2
    assert stored["Parenting styles"].level == 3
    assert stored["Discipline"].level == 3
    edges = list(session.exec(select(Edge).where(Edge.graph_id == graph.id)).all())
    contains = {(edge.from_concept_id, edge.to_concept_id) for edge in edges if edge.type == "contains"}
    parenting = stored["Parenting"].id
    assert (stored["Life skills"].id, parenting) in contains
    assert contains == {
        (stored["Life skills"].id, parenting),
        (parenting, stored["Parenting styles"].id),
        (parenting, stored["Discipline"].id),
        (parenting, stored["Attachment"].id),
    }


def test_dinosaurs_keep_their_parts_and_sit_under_life_sciences(session):
    graph = shared_graph(session)
    session.commit()
    apply_branch(
        session,
        graph=graph,
        parent_concept_id=None,
        instruction="dinosaurs",
        branch={
            "nodes": [
                {"temp_id": "root", "title": "Dinosaurs", "summary": "Archosaurs", "explanation": "Covers dinosaurs."},
                {"temp_id": "hips", "title": "Saurischia of dinosaurs", "summary": "Lizard hips", "explanation": "Covers saurischian dinosaurs."},
            ],
            "edges": [{"from": "root", "to": "hips", "type": "contains", "is_primary_parent": True}],
        },
    )
    session.commit()
    stored = {concept.title: concept for concept in session.exec(select(Concept).where(Concept.origin_graph_id == graph.id)).all()}
    assert stored["Life sciences"].level == 1
    assert stored["Dinosaurs"].level == 2
    assert stored["Saurischia of dinosaurs"].level == 3


def test_a_domain_request_stays_at_level_one(session):
    graph = shared_graph(session)
    session.commit()
    apply_branch(
        session,
        graph=graph,
        parent_concept_id=None,
        instruction="Mathematics",
        branch={
            "nodes": [
                {"temp_id": "math", "title": "Mathematics", "summary": "Number and shape", "explanation": "Covers mathematics."},
                {"temp_id": "algebra", "title": "Algebra", "summary": "Equations", "explanation": "Covers algebra."},
            ],
            "edges": [],
        },
    )
    session.commit()
    stored = {concept.title: concept for concept in session.exec(select(Concept).where(Concept.origin_graph_id == graph.id)).all()}
    assert set(stored) == {"Mathematics", "Algebra"}
    assert stored["Mathematics"].level == 1
    assert stored["Algebra"].level == 2


def test_a_part_of_an_existing_topic_sits_under_that_topic(session):
    graph = shared_graph(session)
    session.commit()
    apply_branch(
        session,
        graph=graph,
        parent_concept_id=None,
        instruction="parenting",
        branch={"nodes": [{"temp_id": "root", "title": "Parenting", "summary": "Raising children", "explanation": "Covers parenting."}], "edges": []},
    )
    apply_branch(
        session,
        graph=graph,
        parent_concept_id=None,
        instruction="attachment parenting",
        branch={
            "nodes": [
                {"temp_id": "bond", "title": "Attachment parenting", "summary": "A style", "explanation": "Covers attachment parenting."}
            ],
            "edges": [],
        },
    )
    session.commit()
    stored = {concept.title: concept for concept in session.exec(select(Concept).where(Concept.origin_graph_id == graph.id)).all()}
    assert stored["Attachment parenting"].level == 3
    edges = list(session.exec(select(Edge).where(Edge.graph_id == graph.id)).all())
    assert any(
        edge.from_concept_id == stored["Parenting"].id and edge.to_concept_id == stored["Attachment parenting"].id and edge.type == "contains"
        for edge in edges
    )
    assert not any(
        edge.from_concept_id == stored["Life skills"].id and edge.to_concept_id == stored["Attachment parenting"].id
        for edge in edges
    )
