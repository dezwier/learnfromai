from sqlmodel import func, select

from app.features.knowledge_graph.node_models import KnowledgeEdge, KnowledgeNode
from app.features.knowledge_graph.preferences import neighborhood_counts
from app.features.platform.jobs import claim_next
from app.features.platform.models import GenerationJob
from app.workers.handlers import handle


def _run_queued(session):
    claimed = claim_next(session)
    assert claimed is not None
    job, token = claimed
    handle(job.id, token)
    session.expire_all()
    return session.get(GenerationJob, job.id)


def test_preferences_defaults_and_clamp(client, auth, user, session):
    response = client.get("/api/v1/me/preferences", headers=auth)
    assert response.status_code == 200
    assert response.json()["neighborhood"] == {
        "parents": 2,
        "siblings": 3,
        "children": 4,
        "acquaintances": 4,
        "extended": 12,
    }

    patched = client.patch(
        "/api/v1/me/preferences",
        headers=auth,
        json={"neighborhood": {"parents": 9, "siblings": 1, "children": 3, "acquaintances": 5, "extended": 99}},
    )
    assert patched.status_code == 200
    assert patched.json()["neighborhood"] == {
        "parents": 2,
        "siblings": 2,
        "children": 3,
        "acquaintances": 5,
        "extended": 24,
    }
    session.refresh(user)
    assert neighborhood_counts(user)["siblings"] == 2


def test_dinosaurs_expand_merge_and_bidirectional_edges(client, auth, session):
    first = client.post("/api/v1/knowledge/focus", headers=auth, json={"topic": "dinosaurs"})
    assert first.status_code == 202
    job_id = first.json()["job_id"]
    focus_id = first.json()["focus_node_id"]

    job = _run_queued(session)
    assert job is not None
    assert job.state == "succeeded"
    assert str(job.id) == job_id

    graph = client.get(f"/api/v1/knowledge/graph/{focus_id}", headers=auth)
    assert graph.status_code == 200
    payload = graph.json()
    assert payload["focus_node_id"] == focus_id
    kinds = {node["kind"] for node in payload["nodes"]}
    assert kinds >= {"focus", "parent", "sibling", "child", "related"}
    titles = {node["title"] for node in payload["nodes"]}
    assert "Dinosaurs" in titles
    assert "Reptiles" in titles
    assert "Theropods" in titles
    assert "Paleontology" in titles

    edges = list(session.exec(select(KnowledgeEdge)).all())
    assert edges
    # Every stored relation has an inverse.
    pairs = {(edge.from_id, edge.relation, edge.to_id) for edge in edges}
    for from_id, relation, to_id in list(pairs):
        inverse = {"parent": "child", "child": "parent", "sibling": "sibling", "acquaintance": "acquaintance"}[relation]
        assert (to_id, inverse, from_id) in pairs


def test_complete_neighborhood_skips_second_llm_job(client, auth, session):
    first = client.post("/api/v1/knowledge/focus", headers=auth, json={"topic": "dinosaurs"})
    assert first.status_code == 202
    _run_queued(session)
    before = session.exec(select(func.count()).select_from(GenerationJob)).one()

    again = client.post("/api/v1/knowledge/focus", headers=auth, json={"topic": "dinosaurs"})
    assert again.status_code == 200
    assert again.json()["focus_node_id"]
    assert "job_id" not in again.json() or again.json().get("nodes")
    after = session.exec(select(func.count()).select_from(GenerationJob)).one()
    assert after == before


def test_higher_child_count_reenqueues(client, auth, session):
    first = client.post("/api/v1/knowledge/focus", headers=auth, json={"topic": "dinosaurs"})
    assert first.status_code == 202
    focus_id = first.json()["focus_node_id"]
    _run_queued(session)

    client.patch("/api/v1/me/preferences", headers=auth, json={"neighborhood": {"children": 5}})
    again = client.post("/api/v1/knowledge/focus", headers=auth, json={"node_id": focus_id})
    assert again.status_code == 202
    assert again.json()["job_id"]


def test_resume_empty_and_latest(client, auth, other_auth, session):
    empty = client.get("/api/v1/knowledge/graph", headers=auth)
    assert empty.status_code == 200
    assert empty.json()["nodes"] == []

    queued = client.post("/api/v1/knowledge/focus", headers=auth, json={"topic": "dinosaurs"})
    focus_id = queued.json()["focus_node_id"]
    _run_queued(session)

    resumed = client.get("/api/v1/knowledge/graph", headers=auth)
    assert resumed.status_code == 200
    assert resumed.json()["focus_node_id"] == focus_id

    other = client.get("/api/v1/knowledge/graph", headers=other_auth)
    assert other.status_code == 200
    assert other.json()["nodes"] == []


def test_knowledge_nodes_autocomplete(client, auth, session):
    session.add_all(
        [
            KnowledgeNode(name="Dinosaurs", name_key="dinosaurs", description="Extinct reptiles."),
            KnowledgeNode(name="Theropods", name_key="theropods", description="Bipedal dinosaurs."),
            KnowledgeNode(name="Birds", name_key="birds", description="Flying vertebrates."),
        ]
    )
    session.commit()

    empty = client.get("/api/v1/knowledge/nodes", headers=auth, params={"q": ""})
    assert empty.status_code == 200
    assert empty.json()["nodes"] == []

    hit = client.get("/api/v1/knowledge/nodes", headers=auth, params={"q": "dino"})
    assert hit.status_code == 200
    titles = [row["title"] for row in hit.json()["nodes"]]
    assert titles == ["Dinosaurs"]

    existing = client.get(f"/api/v1/knowledge/graph/{hit.json()['nodes'][0]['id']}", headers=auth)
    assert existing.status_code == 200
    assert existing.json()["focus_node_id"] == hit.json()["nodes"][0]["id"]
    before = session.exec(select(func.count()).select_from(GenerationJob)).one()
    assert before == 0


def test_name_collision_can_insert_second_node(session, user):
    from app.features.knowledge_graph.neighborhood import _upsert_named
    from app.features.platform.neighborhood_llm import FakeNeighborhoodLLM

    class DistinctFake(FakeNeighborhoodLLM):
        def match_topics(self, candidates):
            return {"matches": {str(item.get("key")): None for item in candidates}}, {
                "model": "fake",
                "input_tokens": 1,
                "output_tokens": 1,
                "estimated_cost_usd": 0,
            }

    first = KnowledgeNode(name="Bass", name_key="bass", description="A fish.")
    session.add(first)
    session.commit()
    second = _upsert_named(
        session,
        llm=DistinctFake(),
        user_id=user.id,
        job_id=None,
        name="Bass",
        description="A low musical range.",
    )
    session.commit()
    assert second.id != first.id
    assert session.exec(select(func.count()).select_from(KnowledgeNode)).one() == 2


def test_near_duplicate_titles_map_together(session, user):
    from app.features.knowledge_graph.neighborhood import _upsert_named, ensure_focus_node
    from app.features.platform.neighborhood_llm import FakeNeighborhoodLLM

    dinosaurs = KnowledgeNode(
        name="Dinosaurs",
        name_key="dinosaurs",
        description="Extinct Mesozoic reptiles.",
    )
    last_dance = KnowledgeNode(
        name="The Last Dance",
        name_key="the-last-dance",
        description="A documentary miniseries about Michael Jordan.",
    )
    session.add_all([dinosaurs, last_dance])
    session.commit()

    llm = FakeNeighborhoodLLM()
    singular = _upsert_named(
        session,
        llm=llm,
        user_id=user.id,
        job_id=None,
        name="Dinosaur",
        description="An extinct reptile clade.",
    )
    documentary = _upsert_named(
        session,
        llm=llm,
        user_id=user.id,
        job_id=None,
        name="The Last Dance Documentary",
        description="Documentary about the 1990s Chicago Bulls.",
    )
    focus = ensure_focus_node(session, topic="Dinosauria")
    session.commit()

    assert singular.id == dinosaurs.id
    assert documentary.id == last_dance.id
    assert focus.id == dinosaurs.id
    assert session.exec(select(func.count()).select_from(KnowledgeNode)).one() == 2
