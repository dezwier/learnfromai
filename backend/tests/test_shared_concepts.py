from app.features.knowledge_graph.identity import canonical_key_for, same_topic


def test_plural_titles_share_a_key():
    assert same_topic("Fossil", "Fossils")
    assert canonical_key_for("Decision Trees") == "decision-trees"
    assert not same_topic("Birds", "Mammals")
