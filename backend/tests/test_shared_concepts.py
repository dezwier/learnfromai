from app.features.knowledge_graph.identity import canonical_key_for, same_topic


def test_plural_titles_share_a_key():
    assert same_topic("Fossil", "Fossils")
    assert same_topic("Dinosaur", "Dinosaurs")
    assert same_topic("Dinosaur", "Dinosauria")
    assert same_topic("Dinosaurs", "Dinosauria")
    assert same_topic("Ornithischia", "Ornithischians")
    assert same_topic("The Last Dance", "The Last Dance Documentary")
    assert same_topic("Paleontology", "Palaeontology")
    assert same_topic("Archeology", "Archaeology")
    assert same_topic("Theropoda", "Theropods")
    assert same_topic("Sauropoda", "Sauropods")
    assert canonical_key_for("Decision Trees") == "decision-trees"
    assert not same_topic("Birds", "Mammals")
    assert not same_topic("Bass", "Bass Guitar")
