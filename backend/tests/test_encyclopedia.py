from app.features.platform.encyclopedia import (
    Article,
    article_graph,
    graph_from_article,
    scoped_title,
)

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
    assert titles == ['Dinosaur', '"Dinosaur renaissance" and beyond', "Anatomy of dinosaur", "Skull of dinosaur"]
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
    assert [node["title"] for node in branch["nodes"]] == ["Dinosaurs", '"Dinosaur renaissance" and beyond']


def test_titles_name_the_subject_and_child_articles_go_deeper():
    assert scoped_title("Classification", "Dinosaurs") == "Classification of dinosaurs"
    assert scoped_title("Early dinosaur research", "Dinosaurs") == "Early dinosaur research"
    assert scoped_title("Origin of birds", "Dinosaurs") == "Origin of birds (dinosaurs)"

    def fetch(query: str):
        folded = query.lower()
        if folded == "dinosaurs":
            return Article(
                "Dinosaur",
                "== Classification ==\nHow the group is divided.\n",
                {"classification": "Dinosaur classification"},
            )
        if "classification" in folded:
            return Article(
                "Dinosaur classification",
                "== Benton classification ==\nA scheme.\n\n=== Saurischia ===\nLizard-hipped dinosaurs.\n",
                {},
            )
        if folded == "saurischia":
            return Article("Saurischia", "== Theropoda ==\nThe carnivorous dinosaurs.\n", {})
        return Article(query, f"{query} is a part of this subject.", {})

    branch = article_graph({"instruction": "dinosaurs", "existing": [], "max_new_concepts": 80}, fetch=fetch)
    levels = {node["title"]: node["level"] for node in branch["nodes"]}
    assert levels["Classification of dinosaurs"] == 1
    assert levels["Saurischia of dinosaurs"] > levels["Classification of dinosaurs"]
    assert levels["Theropoda of dinosaurs"] > levels["Saurischia of dinosaurs"]

    def unrelated(query: str):
        if query.lower() == "dinosaurs":
            return Article("Dinosaur", "== Classification ==\nHow they are grouped.\n", {"classification": "Ink"})
        return Article("Ink", "== Predator distraction ==\nCephalopods release ink.\n", {})

    shallow = article_graph({"instruction": "dinosaurs", "existing": [], "max_new_concepts": 80}, fetch=unrelated)
    titles = {node["title"] for node in shallow["nodes"]}
    assert "Classification of dinosaurs" in titles
    assert "Predator distraction of dinosaurs" not in titles
