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
    assert len(list(session.exec(select(Concept).where(Concept.origin_graph_id == graph.id)).all())) == 2
