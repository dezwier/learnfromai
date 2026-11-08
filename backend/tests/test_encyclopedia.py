from app.features.platform.encyclopedia import article_graph, graph_from_article

ARTICLE = """
Dinosaurs are a diverse group of reptiles. They include birds and extinct forms.

== "Dinosaur renaissance" and beyond ==
Research after the 1970s. This covers the modern view of dinosaurs.

== Anatomy ==
The skeleton and soft tissue. This part covers the body of a dinosaur.

=== Skull ===
The head and jaws. This covers how dinosaurs bit and sensed the world.

== See also ==
Other pages that are not part of the topic.

== References ==
Cited works.
"""


def test_article_becomes_a_contains_tree_without_the_back_matter():
    branch = graph_from_article("Dinosaur", ARTICLE, existing=[], limit=80)
    titles = [node["title"] for node in branch["nodes"]]
    assert titles == ['Dinosaur', '"Dinosaur renaissance" and beyond', "Anatomy", "Skull"]
    assert branch["truncated"] is False
    by_id = {node["temp_id"]: node for node in branch["nodes"]}
    assert by_id["root"]["level"] == 0
    assert "reptiles" in by_id["root"]["explanation"]
    assert by_id["s1"]["level"] == 1
    assert by_id["s2"]["level"] == 2
    assert {(edge["from"], edge["to"], edge["type"]) for edge in branch["edges"]} == {
        ("root", "s0", "contains"),
        ("root", "s1", "contains"),
        ("s1", "s2", "contains"),
    }


def test_existing_topic_is_reused_and_the_graph_stops_at_the_cap():
    existing = [{"concept_id": "dino-1", "title": "Dinosaurs", "canonical_key": "dinosaurs"}]
    branch = article_graph(
        {"instruction": "dinosaurs", "existing": existing, "max_new_concepts": 2},
        fetch=lambda query: ("Dinosaur", ARTICLE),
    )
    root = branch["nodes"][0]
    assert root["concept_id"] == "dino-1"
    assert branch["truncated"] is True
    assert [node["title"] for node in branch["nodes"]] == ["Dinosaur", '"Dinosaur renaissance" and beyond']
