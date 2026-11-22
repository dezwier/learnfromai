from uuid import UUID

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


def test_preferences_neighborhood_is_global(client, auth, user, session):
    response = client.get("/api/v1/me/preferences", headers=auth)
    assert response.status_code == 200
    body = response.json()["neighborhood"]
    assert body["total"] == 16
    assert body["extended"] == 14
    assert body["canvas_max"] == 30
    assert body["min_per_bucket"] == 2
    assert response.json()["llm_provider"] == "openai"

    # Personal neighborhood patches are ignored; sizes stay global.
    patched = client.patch(
        "/api/v1/me/preferences",
        headers=auth,
        json={"neighborhood": {"total": 99, "extended": 99}},
    )
    assert patched.status_code == 200
    assert patched.json()["neighborhood"] == {
        "total": 16,
        "extended": 14,
        "canvas_max": 30,
        "min_per_bucket": 2,
    }
    session.refresh(user)
    assert "neighborhood" not in (user.preferences or {})
    assert neighborhood_counts(user) == {
        "total": 16,
        "extended": 14,
        "canvas_max": 30,
        "min_per_bucket": 2,
    }


def test_llm_provider_preference(client, auth, user, session):
    from app.features.knowledge_graph.preferences import llm_provider_for

    bad = client.patch(
        "/api/v1/me/preferences",
        headers=auth,
        json={"llm_provider": "claude"},
    )
    assert bad.status_code == 422

    patched = client.patch(
        "/api/v1/me/preferences",
        headers=auth,
        json={"llm_provider": "chatgpt"},
    )
    assert patched.status_code == 200
    assert patched.json()["llm_provider"] == "openai"
    session.refresh(user)
    assert llm_provider_for(user) == "openai"
    assert user.preferences.get("llm_provider") == "openai"

    back = client.patch(
        "/api/v1/me/preferences",
        headers=auth,
        json={"llm_provider": "gemini"},
    )
    assert back.status_code == 200
    assert back.json()["llm_provider"] == "gemini"


def test_stored_personal_neighborhood_ignored(client, auth, user, session):
    user.preferences = {
        "neighborhood": {
            "parents": 2,
            "siblings": 3,
            "children": 4,
            "acquaintances": 4,
            "extended": 12,
            "total": 14,
        }
    }
    session.add(user)
    session.commit()
    counts = neighborhood_counts(user)
    assert counts["total"] == 16
    assert counts["extended"] == 14
    assert counts["canvas_max"] == 30


def test_dinosaurs_expand_merge_and_bidirectional_edges(client, auth, session):
    first = client.post("/api/v1/knowledge/focus", headers=auth, json={"topic": "dinosaurs", "expand": True})
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
    first = client.post("/api/v1/knowledge/focus", headers=auth, json={"topic": "dinosaurs", "expand": True})
    assert first.status_code == 202
    _run_queued(session)
    before = session.exec(select(func.count()).select_from(GenerationJob)).one()

    again = client.post("/api/v1/knowledge/focus", headers=auth, json={"topic": "dinosaurs", "expand": True})
    assert again.status_code == 200
    assert again.json()["focus_node_id"]
    assert "job_id" not in again.json() or again.json().get("nodes")
    after = session.exec(select(func.count()).select_from(GenerationJob)).one()
    assert after == before


def test_focus_without_expand_does_not_enqueue(client, auth, session):
    opened = client.post("/api/v1/knowledge/focus", headers=auth, json={"topic": "dinosaurs"})
    assert opened.status_code == 200
    body = opened.json()
    assert body["incomplete"] is True
    assert body.get("job_id") is None
    assert body["focus_node_id"]
    assert session.exec(select(func.count()).select_from(GenerationJob)).one() == 0

    resumed = client.get("/api/v1/knowledge/graph", headers=auth)
    assert resumed.status_code == 200
    assert resumed.json()["focus_node_id"] == body["focus_node_id"]
    assert resumed.json().get("job_id") is None
    assert session.exec(select(func.count()).select_from(GenerationJob)).one() == 0

    by_id = client.get(f"/api/v1/knowledge/graph/{body['focus_node_id']}", headers=auth)
    assert by_id.status_code == 200
    assert by_id.json()["incomplete"] is True
    assert session.exec(select(func.count()).select_from(GenerationJob)).one() == 0


def test_resume_empty_and_latest(client, auth, other_auth, session):
    empty = client.get("/api/v1/knowledge/graph", headers=auth)
    assert empty.status_code == 200
    assert empty.json()["nodes"] == []

    queued = client.post("/api/v1/knowledge/focus", headers=auth, json={"topic": "dinosaurs", "expand": True})
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


def test_delete_knowledge_node_cascades_atoms_and_progress(client, auth, session, user):
    from app.features.content.models import KnowledgeBit
    from app.features.knowledge_graph.node_models import KnowledgeRequest, KnowledgeRequestNode
    from app.features.node_image.pack_models import KnowledgePackImage
    from app.features.platform.models import GenerationJob, GenerationJobWatcher
    from app.features.reviews.models import UserPackReview
    from app.features.user_events.models import UserTopicEvent

    node = KnowledgeNode(name="Softmax", name_key="softmax-del", description="Normalize.")
    other = KnowledgeNode(name="Attention", name_key="attention-del", description="Weights.")
    session.add_all([node, other])
    session.commit()
    session.add_all(
        [
            KnowledgeEdge(from_id=node.id, relation="sibling", to_id=other.id),
            KnowledgeEdge(from_id=other.id, relation="sibling", to_id=node.id),
            KnowledgeBit(
                node_id=node.id,
                pack_index=1,
                kind="learn",
                body={"title": "Tip", "markdown": "About Softmax."},
            ),
            KnowledgeBit(
                node_id=node.id,
                pack_index=1,
                kind="check1",
                body={
                    "type": "mc",
                    "question": "Q?",
                    "choices": ["a", "b", "c", "d"],
                    "answer_index": 0,
                    "explanation": "a",
                },
            ),
            KnowledgePackImage(
                node_id=node.id,
                pack_index=1,
                image_url=f"/knowledge/nodes/{node.id}/packs/1/image/file",
                image_bytes=b"\x89PNG\r\n\x1a\n",
            ),
            UserTopicEvent(
                user_id=user.id,
                node_id=node.id,
                kind="learn",
                payload={"pack_index": 1},
            ),
            UserTopicEvent(
                user_id=user.id,
                node_id=node.id,
                kind="check1",
                payload={"pack_index": 1, "correct": True},
            ),
            UserPackReview(user_id=user.id, node_id=node.id, pack_index=1, leitner_bin=1),
        ]
    )
    job = GenerationJob(
        type="expand_content",
        state="succeeded",
        payload={"node_id": str(node.id)},
    )
    session.add(job)
    session.flush()
    session.add(
        GenerationJobWatcher(
            job_id=job.id,
            user_id=user.id,
            node_id=node.id,
            title=node.name,
        )
    )
    # Focused request with neighbor links — this was the production 500.
    focus_req = KnowledgeRequest(user_id=user.id, focus_id=node.id)
    session.add(focus_req)
    session.flush()
    focus_req_id = focus_req.id
    session.add_all(
        [
            KnowledgeRequestNode(
                request_id=focus_req_id, node_id=node.id, distance=0, kind="focus"
            ),
            KnowledgeRequestNode(
                request_id=focus_req_id, node_id=other.id, distance=1, kind="sibling"
            ),
        ]
    )
    session.commit()

    node_id = node.id
    other_id = other.id
    deleted = client.delete(f"/api/v1/knowledge/nodes/{node_id}", headers=auth)
    assert deleted.status_code == 200, deleted.text
    body = deleted.json()
    assert body["deleted"] is True
    assert body["edges_removed"] == 2
    assert body["bits_deleted"] == 2
    assert body["images_deleted"] == 1
    assert body["events_deleted"] == 2
    assert body["reviews_deleted"] == 1
    assert body["watchers_deleted"] == 1
    assert body["requests_deleted"] == 1

    session.expire_all()
    assert session.get(KnowledgeNode, node_id) is None
    assert session.exec(select(KnowledgeBit).where(KnowledgeBit.node_id == node_id)).all() == []
    assert (
        session.exec(select(KnowledgePackImage).where(KnowledgePackImage.node_id == node_id)).all()
        == []
    )
    assert session.exec(select(UserTopicEvent).where(UserTopicEvent.node_id == node_id)).all() == []
    assert session.exec(select(UserPackReview).where(UserPackReview.node_id == node_id)).all() == []
    assert (
        session.exec(select(GenerationJobWatcher).where(GenerationJobWatcher.node_id == node_id)).all()
        == []
    )
    assert session.get(KnowledgeRequest, focus_req_id) is None
    assert session.exec(select(KnowledgeRequestNode)).all() == []
    # Sibling remains; only the deleted node's edges are gone.
    assert session.get(KnowledgeNode, other_id) is not None
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


def test_build_subgraph_caps_extended_keeps_all_directs(session, user):
    """All directs always shown; extended only fills leftover canvas slots."""
    from app.features.knowledge_graph.neighborhood import build_subgraph

    focus = KnowledgeNode(name="Focus", name_key="focus-cap", description="x")
    session.add(focus)
    session.flush()
    directs = []
    for i in range(20):
        node = KnowledgeNode(name=f"Direct {i:02d}", name_key=f"direct-{i:02d}", description="d")
        directs.append(node)
        session.add(node)
    session.flush()
    for node in directs:
        session.add(KnowledgeEdge(from_id=focus.id, relation="child", to_id=node.id))
        session.add(KnowledgeEdge(from_id=node.id, relation="parent", to_id=focus.id))
        # One extended hanging off each direct.
        ext = KnowledgeNode(
            name=f"Ext {node.name_key}",
            name_key=f"ext-{node.name_key}",
            description="e",
        )
        session.add(ext)
        session.flush()
        session.add(KnowledgeEdge(from_id=node.id, relation="child", to_id=ext.id))
        session.add(KnowledgeEdge(from_id=ext.id, relation="parent", to_id=node.id))
    session.commit()

    payload = build_subgraph(
        session,
        focus,
        max_extended=14,
        counts={"total": 16, "extended": 14, "canvas_max": 30},
    )
    nodes = payload["nodes"]
    assert len(nodes) == 30
    kinds = [node["kind"] for node in nodes]
    assert kinds.count("focus") == 1
    assert kinds.count("child") == 20
    assert kinds.count("extended") == 9

    # Many directs: still show all of them; no extended; may exceed canvas_max.
    focus2 = KnowledgeNode(name="Focus2", name_key="focus-cap-2", description="x")
    session.add(focus2)
    session.flush()
    for i in range(35):
        node = KnowledgeNode(name=f"D2 {i:02d}", name_key=f"d2-{i:02d}", description="d")
        session.add(node)
        session.flush()
        session.add(KnowledgeEdge(from_id=focus2.id, relation="sibling", to_id=node.id))
        session.add(KnowledgeEdge(from_id=node.id, relation="sibling", to_id=focus2.id))
        ext = KnowledgeNode(name=f"E2 {i:02d}", name_key=f"e2-{i:02d}", description="e")
        session.add(ext)
        session.flush()
        session.add(KnowledgeEdge(from_id=node.id, relation="child", to_id=ext.id))
    session.commit()

    big = build_subgraph(
        session,
        focus2,
        max_extended=14,
        counts={"total": 16, "extended": 14, "canvas_max": 30},
    )
    big_kinds = [node["kind"] for node in big["nodes"]]
    assert big_kinds.count("focus") == 1
    assert big_kinds.count("sibling") == 35
    assert big_kinds.count("extended") == 0
    assert len(big["nodes"]) == 36


def test_build_subgraph_keeps_description_on_focus_only(session, user):
    from app.features.knowledge_graph.neighborhood import build_subgraph

    focus = KnowledgeNode(
        name="Dinosaurs",
        name_key="dinosaurs",
        description="Extinct reptiles.",
        image_url="/knowledge/nodes/focus/image/file",
    )
    child = KnowledgeNode(
        name="Theropods",
        name_key="theropods",
        description="Bipedal dinosaurs.",
        image_url="/knowledge/nodes/child/image/file",
    )
    session.add_all([focus, child])
    session.commit()
    session.add_all(
        [
            KnowledgeEdge(from_id=focus.id, relation="child", to_id=child.id),
            KnowledgeEdge(from_id=child.id, relation="parent", to_id=focus.id),
        ]
    )
    session.commit()

    payload = build_subgraph(session, focus, max_extended=12)
    by_title = {node["title"]: node for node in payload["nodes"]}
    assert by_title["Dinosaurs"]["description"] == "Extinct reptiles."
    assert by_title["Dinosaurs"]["image_url"] == "/knowledge/nodes/focus/image/file"
    assert by_title["Dinosaurs"]["image_thumb_url"].endswith("?variant=thumb")
    assert by_title["Theropods"]["description"] is None
    assert by_title["Theropods"]["image_url"] is None
    assert by_title["Theropods"]["image_thumb_url"].endswith("?variant=thumb")


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
        last_counts = None

        def generate_neighborhood(self, topic, counts):
            BatchSpy.last_counts = counts
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
            "from_existing_focus": True,
            "total": 4,
            "min_per_bucket": 1,
            "extended": 12,
        },
    )
    session.add(job)
    session.commit()

    import app.features.knowledge_graph.neighborhood as neighborhood_mod

    original = neighborhood_mod.get_neighborhood_llm
    neighborhood_mod.get_neighborhood_llm = lambda *args, **kwargs: BatchSpy()
    try:
        BatchSpy.calls = 0
        expand_neighborhood(session, job)
    finally:
        neighborhood_mod.get_neighborhood_llm = original

    assert BatchSpy.calls == 1
    assert BatchSpy.last_candidates is not None
    assert len(BatchSpy.last_candidates) >= 1
    assert BatchSpy.last_counts is not None
    assert BatchSpy.last_counts.get("total") == 4
    assert BatchSpy.last_counts.get("exclude_titles") == []
    for item in BatchSpy.last_candidates:
        assert "name" in item
        assert "description" in item
        assert "existing" in item
        assert len(item["existing"]) <= 16
        for row in item["existing"]:
            assert set(row) >= {"id", "name", "description"}


def test_existing_focus_skips_focus_sameness_and_fills_deficit(session, user):
    """Scenario 3: known tile → under-budget → neighborhood with need/excludes; no focus sameness."""
    from app.features.knowledge_graph.neighborhood import expand_neighborhood
    from app.features.platform.models import GenerationJob

    class Spy:
        name = "fake"
        match_calls = 0
        generate_counts = None

        def generate_neighborhood(self, topic, counts):
            Spy.generate_counts = counts
            need = int(counts.get("total") or 0)
            return {
                "focus": {"name": "Dinosaurs", "description": "Extinct reptiles."},
                "parents": [{"name": "Reptiles", "description": "Scaled vertebrates."}][:need],
                "siblings": [],
                "children": [{"name": "Theropods", "description": "Bipedal dinosaurs."}]
                if need > 1
                else [],
                "acquaintances": [],
            }, {"model": "fake", "input_tokens": 1, "output_tokens": 1, "estimated_cost_usd": 0}

        def match_topics(self, candidates):
            Spy.match_calls += 1
            return {"matches": {str(item.get("key")): None for item in candidates}}, {
                "model": "fake",
                "input_tokens": 1,
                "output_tokens": 1,
                "estimated_cost_usd": 0,
            }

    focus = KnowledgeNode(name="Dinosaurs", name_key="dinosaurs", description="Extinct reptiles.")
    parent = KnowledgeNode(name="Animals", name_key="animals", description="Living organisms.")
    session.add_all([focus, parent])
    session.commit()
    session.add_all(
        [
            KnowledgeEdge(from_id=focus.id, relation="parent", to_id=parent.id),
            KnowledgeEdge(from_id=parent.id, relation="child", to_id=focus.id),
        ]
    )
    session.commit()

    job = GenerationJob(
        type="expand_neighborhood",
        state="running",
        user_id=user.id,
        payload={
            "focus_id": str(focus.id),
            "topic": "Dinosaurs",
            "from_existing_focus": True,
            "total": 3,
            "min_per_bucket": 1,
            "extended": 12,
        },
    )
    session.add(job)
    session.commit()

    import app.features.knowledge_graph.neighborhood as neighborhood_mod

    original = neighborhood_mod.get_neighborhood_llm
    neighborhood_mod.get_neighborhood_llm = lambda *args, **kwargs: Spy()
    try:
        Spy.match_calls = 0
        result = expand_neighborhood(session, job)
    finally:
        neighborhood_mod.get_neighborhood_llm = original

    assert result["skipped"] is False
    assert Spy.generate_counts is not None
    assert Spy.generate_counts["total"] == 2
    assert "Animals" in Spy.generate_counts.get("exclude_titles", [])
    # No ambiguous neighbor titles → no sameness call; focus path skipped.
    assert Spy.match_calls == 0


def test_new_topic_reuse_complete_skips_neighborhood(session, user):
    """Scenario 4: new request → retrieve/sameness → exists → budget met → Done."""
    from app.features.knowledge_graph.neighborhood import expand_neighborhood
    from app.features.platform.models import GenerationJob

    class Spy:
        name = "fake"
        generate_calls = 0
        match_calls = 0

        def generate_neighborhood(self, topic, counts):
            Spy.generate_calls += 1
            return {"focus": {"name": topic}, "parents": [], "siblings": [], "children": [], "acquaintances": []}, {
                "model": "fake",
                "input_tokens": 1,
                "output_tokens": 1,
                "estimated_cost_usd": 0,
            }

        def match_topics(self, candidates):
            Spy.match_calls += 1
            return {"matches": {str(item.get("key")): None for item in candidates}}, {
                "model": "fake",
                "input_tokens": 1,
                "output_tokens": 1,
                "estimated_cost_usd": 0,
            }

    keeper = KnowledgeNode(name="Dinosaurs", name_key="dinosaurs", description="Extinct reptiles.")
    provisional = KnowledgeNode(name="Dinosauria", name_key="dinosauria", description=None)
    filler = KnowledgeNode(name="Reptiles", name_key="reptiles", description="Scaled vertebrates.")
    session.add_all([keeper, provisional, filler])
    session.commit()
    # Keeper already meets a tiny budget.
    session.add_all(
        [
            KnowledgeEdge(from_id=keeper.id, relation="parent", to_id=filler.id),
            KnowledgeEdge(from_id=filler.id, relation="child", to_id=keeper.id),
        ]
    )
    session.commit()

    job = GenerationJob(
        type="expand_neighborhood",
        state="running",
        user_id=user.id,
        payload={
            "focus_id": str(provisional.id),
            "topic": "Dinosauria",
            "from_existing_focus": False,
            "total": 1,
            "min_per_bucket": 1,
            "extended": 12,
        },
    )
    session.add(job)
    session.commit()

    import app.features.knowledge_graph.neighborhood as neighborhood_mod

    original = neighborhood_mod.get_neighborhood_llm
    neighborhood_mod.get_neighborhood_llm = lambda *args, **kwargs: Spy()
    try:
        Spy.generate_calls = 0
        Spy.match_calls = 0
        result = expand_neighborhood(session, job)
    finally:
        neighborhood_mod.get_neighborhood_llm = original

    assert result["skipped"] is True
    assert result["focus_id"] == str(keeper.id)
    assert Spy.generate_calls == 0
    assert session.get(KnowledgeNode, provisional.id) is None


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


def test_expand_survives_focus_merged_away_during_resolve(session, user):
    """Consolidate may delete the job's focus_id; expand must follow the topic to the keeper."""
    from app.features.knowledge_graph.neighborhood import expand_neighborhood
    from app.features.platform.models import GenerationJob

    keeper = KnowledgeNode(name="Dinosaurs", name_key="dinosaurs", description="Extinct reptiles.")
    drop = KnowledgeNode(name="Dinosaur", name_key="dinosaur", description=None)
    session.add_all([keeper, drop])
    session.commit()

    job = GenerationJob(
        type="expand_neighborhood",
        state="running",
        user_id=user.id,
        payload={
            "focus_id": str(drop.id),
            "topic": "Dinosaur",
            "parents": 2,
            "siblings": 3,
            "children": 4,
            "acquaintances": 4,
        },
    )
    session.add(job)
    session.commit()

    result = expand_neighborhood(session, job)
    session.commit()

    assert result["focus_id"] == str(keeper.id)
    assert session.get(KnowledgeNode, drop.id) is None
    from app.features.knowledge_graph.neighborhood import relation_counts

    have = relation_counts(session, keeper.id)
    assert have["parents"] >= 2
    assert have["siblings"] >= 3
    assert have["children"] >= 4
    assert have["acquaintances"] >= 4


def test_failed_expand_can_be_reenqueued(client, auth, session):
    first = client.post("/api/v1/knowledge/focus", headers=auth, json={"topic": "dinosaurs", "expand": True})
    assert first.status_code == 202
    job_id = first.json()["job_id"]
    job = session.get(GenerationJob, UUID(job_id))
    assert job is not None
    job.state = "failed"
    job.error_code = "GENERATION_UNAVAILABLE"
    session.add(job)
    session.commit()

    again = client.post("/api/v1/knowledge/focus", headers=auth, json={"topic": "dinosaurs", "expand": True})
    assert again.status_code == 202
    assert again.json()["job_id"] != job_id
    fresh = _run_queued(session)
    assert fresh is not None
    assert fresh.state == "succeeded"
