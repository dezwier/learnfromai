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


def test_patch_and_delete_knowledge_node(client, auth, session):
    node = KnowledgeNode(name="Theropods", name_key="theropods", description="Bipedal dinosaurs.")
    other = KnowledgeNode(name="Dinosaurs", name_key="dinosaurs", description="Extinct reptiles.")
    session.add_all([node, other])
    session.commit()
    session.add_all(
        [
            KnowledgeEdge(from_id=node.id, relation="parent", to_id=other.id),
            KnowledgeEdge(from_id=other.id, relation="child", to_id=node.id),
        ]
    )
    session.commit()

    patched = client.patch(
        f"/api/v1/knowledge/nodes/{node.id}",
        headers=auth,
        json={"name": "Theropoda", "description": "A dinosaur clade."},
    )
    assert patched.status_code == 200
    assert patched.json()["title"] == "Theropoda"
    assert patched.json()["description"] == "A dinosaur clade."
    session.refresh(node)
    assert node.name_key == "theropoda"

    node_id = node.id
    deleted = client.delete(f"/api/v1/knowledge/nodes/{node_id}", headers=auth)
    assert deleted.status_code == 200
    assert deleted.json()["deleted"] is True
    assert deleted.json()["edges_removed"] == 2
    session.expire_all()
    assert session.get(KnowledgeNode, node_id) is None
    assert session.exec(select(KnowledgeEdge)).all() == []


def test_build_subgraph_hides_near_duplicate_neighbors(session, user):
    from app.features.knowledge_graph.neighborhood import build_subgraph

    focus = KnowledgeNode(name="Dinosaurs", name_key="dinosaurs", description="Extinct reptiles.")
    twin = KnowledgeNode(name="Dinosaur", name_key="dinosaur", description="Singular form.")
    child = KnowledgeNode(name="Theropods", name_key="theropods", description="Bipedal dinosaurs.")
    session.add_all([focus, twin, child])
    session.commit()
    session.add_all(
        [
            KnowledgeEdge(from_id=focus.id, relation="child", to_id=twin.id),
            KnowledgeEdge(from_id=twin.id, relation="parent", to_id=focus.id),
            KnowledgeEdge(from_id=focus.id, relation="child", to_id=child.id),
            KnowledgeEdge(from_id=child.id, relation="parent", to_id=focus.id),
        ]
    )
    session.commit()

    payload = build_subgraph(session, focus, max_extended=12)
    titles = {node["title"] for node in payload["nodes"]}
    assert titles == {"Dinosaurs", "Theropods"}


def test_consolidate_merges_existing_near_duplicates(session, user):
    from app.features.knowledge_graph.neighborhood import consolidate_near_duplicates

    keep = KnowledgeNode(name="The Last Dance", name_key="the-last-dance", description="Bulls documentary.")
    drop = KnowledgeNode(
        name="The Last Dance Documentary",
        name_key="the-last-dance-documentary",
        description=None,
    )
    other = KnowledgeNode(name="Basketball", name_key="basketball", description="Sport.")
    session.add_all([keep, drop, other])
    session.commit()
    session.add_all(
        [
            KnowledgeEdge(from_id=drop.id, relation="parent", to_id=other.id),
            KnowledgeEdge(from_id=other.id, relation="child", to_id=drop.id),
        ]
    )
    session.commit()

    assert consolidate_near_duplicates(session) == 1
    session.commit()
    names = {row.name for row in session.exec(select(KnowledgeNode)).all()}
    assert names == {"The Last Dance", "Basketball"}
    edges = list(session.exec(select(KnowledgeEdge)).all())
    assert {(edge.from_id, edge.relation, edge.to_id) for edge in edges} == {
        (keep.id, "parent", other.id),
        (other.id, "child", keep.id),
    }


def test_expand_batches_sameness_into_one_match_topics_call(session, user):
    from app.features.knowledge_graph.neighborhood import expand_neighborhood
    from app.features.platform.models import GenerationJob

    class BatchSpy:
        name = "fake"
        calls = 0
        last_candidates = None

        def generate_neighborhood(self, topic, counts):
            return {
                "focus": {"name": "Dinosaurs", "description": "Extinct reptiles."},
                "parents": [
                    {"name": "Paleontology", "description": "Study of fossils."},
                    {"name": "Reptiles", "description": "Scaled vertebrates."},
                ],
                "siblings": [],
                "children": [
                    {"name": "Theropods", "description": "Bipedal dinosaurs."},
                ],
                "acquaintances": [
                    # Close to "The Last Dance" via media stem, but not same_topic — needs LLM.
                    {"name": "Last Dance Series", "description": "Documentary series about the Bulls."},
                ],
            }, {"model": "fake", "input_tokens": 1, "output_tokens": 1, "estimated_cost_usd": 0}

        def match_topics(self, candidates):
            BatchSpy.calls += 1
            BatchSpy.last_candidates = candidates
            matches = {}
            for item in candidates:
                chosen = None
                for row in item.get("existing") or []:
                    if not isinstance(row, dict):
                        continue
                    existing_name = str(row.get("name") or "")
                    if "last dance" in existing_name.lower():
                        chosen = str(row.get("id"))
                        break
                matches[str(item.get("key"))] = chosen
            return {"matches": matches}, {
                "model": "fake",
                "input_tokens": 1,
                "output_tokens": 1,
                "estimated_cost_usd": 0,
            }

    last_dance = KnowledgeNode(
        name="The Last Dance",
        name_key="the-last-dance",
        description="A documentary miniseries about Michael Jordan.",
    )
    session.add(last_dance)
    session.commit()

    focus = KnowledgeNode(name="Dinosaurs", name_key="dinosaurs", description=None)
    session.add(focus)
    session.commit()
    job = GenerationJob(
        type="expand_neighborhood",
        state="running",
        user_id=user.id,
        payload={
            "focus_id": str(focus.id),
            "topic": "dinosaurs",
            "parents": 2,
            "siblings": 0,
            "children": 1,
            "acquaintances": 1,
        },
    )
    session.add(job)
    session.commit()

    import app.features.knowledge_graph.neighborhood as neighborhood_mod

    original = neighborhood_mod.get_neighborhood_llm
    neighborhood_mod.get_neighborhood_llm = lambda: BatchSpy()
    try:
        BatchSpy.calls = 0
        expand_neighborhood(session, job)
    finally:
        neighborhood_mod.get_neighborhood_llm = original

    assert BatchSpy.calls == 1
    assert BatchSpy.last_candidates is not None
    assert len(BatchSpy.last_candidates) >= 1
    for item in BatchSpy.last_candidates:
        assert "name" in item
        assert "description" in item
        assert "existing" in item
        assert len(item["existing"]) <= 16
        for row in item["existing"]:
            assert set(row) >= {"id", "name", "description"}


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
