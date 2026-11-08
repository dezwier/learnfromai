from uuid import uuid4

from sqlmodel import select

from app.features.graph_extend.service import apply_branch
from app.features.knowledge_graph.domain import creates_cycle
from app.features.knowledge_graph.models import Concept, Edge
from app.features.knowledge_graph.service import shared_graph


def test_cycle_helper_rejects_a_loop():
    left = uuid4()
    right = uuid4()
    assert creates_cycle({left: {right}}, right, left) is True
    assert creates_cycle({left: {right}}, left, right) is False


def test_apply_reuses_links_and_drops_bad_edges(session):
    graph = shared_graph(session)
    biology = Concept(origin_graph_id=graph.id, title="Biology", summary="Life", canonical_key="biology")
    fossil = Concept(origin_graph_id=graph.id, title="Fossil", summary="Remains", canonical_key="fossil")
    session.add(biology)
    session.add(fossil)
    session.commit()

    apply_branch(
        session,
        graph=graph,
        parent_concept_id=biology.id,
        branch={
            "nodes": [
                {"temp_id": "cells", "title": "Cells", "summary": "Units of life"},
                {"temp_id": "fossils", "title": "Fossils", "summary": "Should reuse the existing node"},
                {"temp_id": "noise", "title": "Cells structure", "summary": "Not a subject"},
                {"temp_id": "loose", "title": "Loose note", "summary": "No surviving edge"},
            ],
            "edges": [
                {"from": "cells", "to": "missing", "type": "contains"},
                {"from": "cells", "to": "fossils", "type": "related"},
                {"from": "fossils", "to": "cells", "type": "related"},
                {"from": "loose", "to": "nowhere", "type": "prerequisite"},
            ],
        },
    )
    session.commit()

    concepts = list(session.exec(select(Concept).where(Concept.origin_graph_id == graph.id)).all())
    titles = {concept.title for concept in concepts}
    assert titles == {"Biology", "Fossil", "Cells"}
    cells = next(concept for concept in concepts if concept.title == "Cells")
    edges = list(session.exec(select(Edge).where(Edge.graph_id == graph.id)).all())
    assert any(edge.from_concept_id == biology.id and edge.to_concept_id == cells.id and edge.type == "contains" for edge in edges)
    related = [edge for edge in edges if edge.type == "related"]
    assert len(related) == 2
    assert not any(edge.to_concept_id not in {concept.id for concept in concepts} for edge in edges)


def test_contains_cycle_keeps_one_direction(session):
    graph = shared_graph(session)
    session.commit()
    apply_branch(
        session,
        graph=graph,
        parent_concept_id=None,
        branch={
            "nodes": [
                {"temp_id": "a", "title": "Alpha", "summary": "First"},
                {"temp_id": "b", "title": "Beta", "summary": "Second"},
            ],
            "edges": [
                {"from": "a", "to": "b", "type": "contains", "is_primary_parent": True},
                {"from": "b", "to": "a", "type": "contains", "is_primary_parent": True},
                {"from": "a", "to": "b", "type": "prerequisite"},
                {"from": "b", "to": "a", "type": "prerequisite"},
            ],
        },
    )
    session.commit()
    edges = list(session.exec(select(Edge).where(Edge.graph_id == graph.id)).all())
    assert len([edge for edge in edges if edge.type == "contains"]) == 1
    assert len([edge for edge in edges if edge.type == "prerequisite"]) == 1


def test_second_extend_adds_only_missing_edges(session):
    graph = shared_graph(session)
    session.commit()
    branch = {
        "nodes": [
            {"temp_id": "root", "title": "Dinosaurs", "summary": "Archosaurs", "canonical_key": "dinosaurs"},
            {"temp_id": "bird", "title": "Birds", "summary": "Living dinosaurs", "canonical_key": "birds"},
        ],
        "edges": [{"from": "root", "to": "bird", "type": "contains", "is_primary_parent": True}],
    }
    first = apply_branch(session, graph=graph, parent_concept_id=None, branch=branch)
    session.commit()
    extra = {
        **branch,
        "edges": [
            *branch["edges"],
            {"from": "bird", "to": "root", "type": "related"},
        ],
    }
    second = apply_branch(session, graph=graph, parent_concept_id=None, branch=extra)
    session.commit()
    assert first["added_nodes"] == 2
    assert second["added_nodes"] == 0
    assert second["added_edges"] == 1
    stored = list(session.exec(select(Concept).where(Concept.origin_graph_id == graph.id)).all())
    assert len(stored) == 2
    by_title = {concept.title: concept for concept in stored}
    assert by_title["Dinosaurs"].level == 0
    assert by_title["Birds"].level == 1


def test_explanation_reuses_a_covered_topic_and_keeps_a_deeper_part(session):
    graph = shared_graph(session)
    session.commit()
    apply_branch(
        session,
        graph=graph,
        parent_concept_id=None,
        branch={
            "nodes": [
                {
                    "temp_id": "root",
                    "title": "Dinosaurs",
                    "summary": "Archosaurs",
                    "explanation": "Covers archosaurs, including the large reptiles of the Mesozoic.",
                    "level": 0,
                }
            ],
            "edges": [],
        },
    )
    session.commit()
    reused = apply_branch(
        session,
        graph=graph,
        parent_concept_id=None,
        branch={
            "nodes": [
                {
                    "temp_id": "again",
                    "title": "Mesozoic",
                    "summary": "Already inside dinosaurs",
                    "explanation": "Covers the Mesozoic era.",
                    "level": 0,
                }
            ],
            "edges": [],
        },
    )
    deeper = apply_branch(
        session,
        graph=graph,
        parent_concept_id=None,
        branch={
            "nodes": [
                {
                    "temp_id": "birds",
                    "title": "Birds",
                    "summary": "Flying dinosaurs",
                    "explanation": "Covers the range of birds.",
                    "level": 1,
                }
            ],
            "edges": [{"from": "root", "to": "birds", "type": "contains", "is_primary_parent": True}],
        },
    )
    session.commit()
    titles = {concept.title for concept in session.exec(select(Concept).where(Concept.origin_graph_id == graph.id)).all()}
    assert reused["added_nodes"] == 0
    assert deeper["added_nodes"] == 1
    assert titles == {"Dinosaurs", "Birds"}


def test_a_real_explanation_replaces_a_short_placeholder(session):
    graph = shared_graph(session)
    session.commit()
    apply_branch(
        session,
        graph=graph,
        parent_concept_id=None,
        branch={
            "nodes": [
                {
                    "temp_id": "root",
                    "title": "Dinosaurs",
                    "summary": "Dinosaurs",
                    "explanation": "Covers the range of Dinosaurs.",
                    "level": 0,
                }
            ],
            "edges": [],
        },
    )
    long = (
        "Dinosaurs are a diverse group of reptiles from the Mesozoic. "
        "The range includes their anatomy, evolution, classification, and extinction."
    )
    apply_branch(
        session,
        graph=graph,
        parent_concept_id=None,
        branch={
            "nodes": [
                {
                    "temp_id": "root",
                    "title": "Dinosaur",
                    "summary": "Reptiles",
                    "explanation": long,
                    "level": 0,
                },
                {
                    "temp_id": "anatomy",
                    "title": "Anatomy",
                    "summary": "The body",
                    "explanation": "Covers the skeleton and soft tissue of dinosaurs.",
                    "level": 1,
                },
            ],
            "edges": [{"from": "root", "to": "anatomy", "type": "contains", "is_primary_parent": True}],
        },
    )
    session.commit()
    stored = {concept.title: concept for concept in session.exec(select(Concept).where(Concept.origin_graph_id == graph.id)).all()}
    assert set(stored) == {"Dinosaurs", "Anatomy"}
    assert stored["Dinosaurs"].explanation == long
    assert stored["Anatomy"].level == 1
