from datetime import timedelta

import httpx
from sqlalchemy import distinct
from sqlmodel import func, select

from app.core.config import get_settings
from app.core.time import utcnow
from app.features.knowledge_graph.item_models import (
    KnowledgeGraphRequest,
    KnowledgeGraphRequestNode,
    KnowledgeItem,
)
from app.features.knowledge_graph.wikidata import (
    WikidataClient,
    WikiDataError,
    WikiEntity,
    parse_qid,
)

LIFE = 7239
ANIMALS = 20
REPTILES = 30
DINOSAURS = 430
SAURISCHIA = 6
ORNITHISCHIA = 7
GENERA = 8
TOYS = 11
COLORS = 10
LIZARDS = 12


def _item(qid, title, *, subclass=(), taxon=(), instance=(), sitelinks=1, description=None):
    return WikiEntity(
        qid=qid,
        title=title,
        description=description,
        sitelinks=sitelinks,
        subclass_of=tuple(subclass),
        parent_taxon=tuple(taxon),
        instance_of=tuple(instance),
    )


class FakeWikidata:
    def __init__(self, items, children=None):
        self.items = {item.qid: item for item in items}
        self.child_map = {key: list(value) for key, value in (children or {}).items()}
        self.fail_upstream: set[int] = set()
        self.fail_downstream: set[int] = set()
        self.calls: list[tuple] = []

    def close(self):
        return None

    def search(self, name, *, limit=8):
        self.calls.append(("search", name))
        query = name.lower()
        hits = [
            item
            for item in self.items.values()
            if not item.skipped and (query in item.title.lower() or item.title.lower() in query)
        ]
        hits.sort(key=lambda item: (item.title.lower(), item.qid))
        exact = [item for item in hits if item.title.lower() == query or f"{item.title.lower()}s" == query]
        return (exact or hits)[:limit]

    def entities(self, qids):
        self.calls.append(("entities", tuple(qids)))
        found = []
        for qid in qids:
            if qid in self.fail_upstream:
                raise WikiDataError("upstream failed")
            item = self.items.get(qid)
            if item is not None:
                found.append(item)
        return found

    def children(self, qid):
        self.calls.append(("children", qid))
        if qid in self.fail_downstream:
            raise WikiDataError("downstream failed")
        if qid not in self.items:
            raise WikiDataError("missing item")
        return list(self.child_map.get(qid, []))


def _dinosaurs():
    return FakeWikidata(
        [
            _item(LIFE, "organism", sitelinks=40),
            _item(ANIMALS, "animal", taxon=(LIFE,), sitelinks=30),
            _item(REPTILES, "reptile", taxon=(ANIMALS,), sitelinks=20),
            _item(DINOSAURS, "dinosaur", taxon=(REPTILES,), subclass=(COLORS,), sitelinks=50, description="clade of reptiles"),
            _item(SAURISCHIA, "Saurischia", taxon=(DINOSAURS,), sitelinks=12),
            _item(ORNITHISCHIA, "Ornithischia", taxon=(DINOSAURS,), sitelinks=11),
            _item(GENERA, "dinosaur genera", taxon=(SAURISCHIA,), sitelinks=4),
            _item(TOYS, "dinosaur toys", subclass=(DINOSAURS,), sitelinks=2),
            _item(COLORS, "dinosaur colors", subclass=(DINOSAURS,), sitelinks=2),
            _item(LIZARDS, "lizard", taxon=(REPTILES,), sitelinks=8),
            _item(4167836, "Wikimedia category", instance=(4167836,), sitelinks=0),
        ],
        children={
            LIFE: [ANIMALS],
            ANIMALS: [REPTILES],
            REPTILES: [DINOSAURS, LIZARDS],
            DINOSAURS: [SAURISCHIA, ORNITHISCHIA, 4167836],
            SAURISCHIA: [GENERA],
            ORNITHISCHIA: [],
        },
    )


def _install(monkeypatch, fake):
    monkeypatch.setattr("app.features.knowledge_graph.items.WikidataClient", lambda **_kwargs: fake)


def _graph(client, auth, **params):
    return client.get("/api/v1/knowledge/graph", headers=auth, params=params)


def _parent_fetches(fake: FakeWikidata, qid: int) -> list[tuple]:
    return [call for call in fake.calls if call[0] == "entities" and call[1] == (qid,)]


def test_dinosaurs_walks_taxon_parents_children_and_siblings(client, auth, monkeypatch):
    fake = _dinosaurs()
    _install(monkeypatch, fake)

    response = _graph(client, auth, topic="Dinosaurs", up_depth=2, down_depth=1)
    assert response.status_code == 200
    body = response.json()
    assert body["focus_node_id"] == DINOSAURS
    assert body["incomplete"] is False
    titles = {node["title"]: node for node in body["nodes"]}
    assert titles["animal"]["depth"] == -2
    assert titles["reptile"]["depth"] == -1
    assert titles["dinosaur"]["depth"] == 0
    assert titles["dinosaur"]["distance"] == 0
    assert titles["reptile"]["distance"] == 1
    assert titles["animal"]["distance"] == 2
    assert titles["Saurischia"]["depth"] == 1
    assert titles["Saurischia"]["distance"] == 1
    assert titles["Ornithischia"]["depth"] == 1
    assert titles["lizard"]["depth"] == 0
    assert titles["lizard"]["distance"] == 2
    assert "organism" not in titles
    assert "Wikimedia category" not in titles
    assert "dinosaur genera" not in titles
    edges = {(edge["source"], edge["target"], edge["type"]) for edge in body["edges"]}
    assert (REPTILES, DINOSAURS, "parent_child") in edges
    assert (ANIMALS, REPTILES, "parent_child") in edges
    assert (DINOSAURS, SAURISCHIA, "parent_child") in edges
    assert (REPTILES, LIZARDS, "parent_child") in edges
    assert COLORS not in {edge[0] for edge in edges} | {edge[1] for edge in edges}


def test_cycles_stop_and_a_second_search_reuses_the_same_rows(client, auth, other_auth, session, monkeypatch):
    fake = FakeWikidata(
        [
            _item(1, "Alpha", subclass=(2,)),
            _item(2, "Beta", subclass=(1,)),
        ],
        children={1: [2], 2: [1]},
    )
    _install(monkeypatch, fake)
    first = _graph(client, auth, topic="Alpha", up_depth=2, down_depth=2)
    assert first.status_code == 200
    body = first.json()
    assert {node["id"] for node in body["nodes"]} == {1, 2}
    assert fake.calls
    recorded = len(fake.calls)
    fake.calls.clear()

    second = _graph(client, other_auth, topic="beta", up_depth=2, down_depth=2)
    assert second.status_code == 200
    assert second.json()["focus_node_id"] == 2
    assert fake.calls == []
    assert recorded > 0
    count = session.exec(select(func.count()).select_from(KnowledgeItem)).one()
    distinct_ids = session.exec(select(func.count(distinct(KnowledgeItem.wikidata_qid)))).one()
    assert count == distinct_ids == 2
    requests = session.exec(select(KnowledgeGraphRequest)).all()
    assert len(requests) == 2
    distances = session.exec(select(KnowledgeGraphRequestNode)).all()
    assert len(distances) >= 2


def test_overlapping_topic_fetches_only_the_missing_branch(client, auth, other_auth, session, monkeypatch):
    fake = _dinosaurs()
    _install(monkeypatch, fake)
    opened = _graph(client, auth, topic="dinosaur", up_depth=2, down_depth=1)
    assert opened.status_code == 200
    assert session.exec(select(KnowledgeItem).where(KnowledgeItem.wikidata_qid == DINOSAURS)).first() is not None
    fake.calls.clear()

    focused = _graph(client, other_auth, category_id=SAURISCHIA, up_depth=2, down_depth=2)
    assert focused.status_code == 200
    body = focused.json()
    assert body["focus_node_id"] == SAURISCHIA
    titles = {node["title"] for node in body["nodes"]}
    assert "dinosaur genera" in titles
    assert "dinosaur" in titles
    assert not any(call[0] == "children" and call[1] == DINOSAURS for call in fake.calls)
    assert any(call[0] == "children" and call[1] == SAURISCHIA for call in fake.calls)
    rows = session.exec(select(KnowledgeItem.wikidata_qid)).all()
    assert len(rows) == len(set(rows))
    again = _graph(client, auth, category_id=SAURISCHIA, up_depth=2, down_depth=2)
    assert again.status_code == 200
    assert session.exec(select(func.count()).select_from(KnowledgeItem)).one() == len(set(rows))


def test_failed_fetch_stays_incomplete_and_a_stale_direction_is_read_again(client, auth, session, monkeypatch):
    fake = _dinosaurs()
    fake.fail_upstream.add(DINOSAURS)
    _install(monkeypatch, fake)
    partial = _graph(client, auth, topic="dinosaur", up_depth=1, down_depth=0)
    assert partial.status_code == 200
    assert partial.json()["incomplete"] is True
    assert partial.json()["nodes"] == [{"id": DINOSAURS, "title": "dinosaur", "depth": 0, "distance": 0}]
    assert partial.json()["edges"] == []
    stored = session.exec(select(KnowledgeItem).where(KnowledgeItem.wikidata_qid == DINOSAURS)).one()
    assert stored.upstream_complete is False

    fake.fail_upstream.clear()
    restored = _graph(client, auth, topic="dinosaur", up_depth=1, down_depth=0)
    assert restored.status_code == 200
    assert restored.json()["incomplete"] is False
    assert {edge["source"] for edge in restored.json()["edges"]} == {REPTILES}

    session.expire_all()
    item = session.exec(select(KnowledgeItem).where(KnowledgeItem.wikidata_qid == DINOSAURS)).one()
    item.upstream_fetched_at = utcnow() - timedelta(days=31)
    session.add(item)
    session.commit()
    fake.calls.clear()
    stale = _graph(client, auth, topic="dinosaur", up_depth=1, down_depth=0)
    assert stale.status_code == 200
    assert _parent_fetches(fake, DINOSAURS)

    session.expire_all()
    item = session.exec(select(KnowledgeItem).where(KnowledgeItem.wikidata_qid == DINOSAURS)).one()
    assert item.upstream_complete is True
    fake.calls.clear()
    fresh = _graph(client, auth, topic="dinosaur", up_depth=1, down_depth=0)
    assert fresh.status_code == 200
    assert _parent_fetches(fake, DINOSAURS) == []


def test_ambiguous_search_and_domain_root_stop(client, auth, session, monkeypatch):
    fake = _dinosaurs()
    _install(monkeypatch, fake)
    ambiguous = _graph(client, auth, topic="dino")
    assert ambiguous.status_code == 409
    candidates = {item["title"] for item in ambiguous.json()["details"]["candidates"]}
    assert "dinosaur colors" in candidates
    assert "dinosaur toys" in candidates
    assert session.exec(select(func.count()).select_from(KnowledgeItem)).one() == 0

    rooted = _graph(client, auth, topic="animal", up_depth=2, down_depth=0)
    assert rooted.status_code == 200
    titles = {node["title"] for node in rooted.json()["nodes"]}
    assert "organism" in titles
    assert rooted.json()["nodes"]
    organism = session.exec(select(KnowledgeItem).where(KnowledgeItem.wikidata_qid == LIFE)).one()
    assert organism.upstream_complete is True
    assert organism.domain_qid == LIFE


def test_missing_topic_and_item_budget(client, auth, monkeypatch):
    fake = _dinosaurs()
    _install(monkeypatch, fake)
    missing = _graph(client, auth, topic="No such item")
    assert missing.status_code == 404
    empty = client.get("/api/v1/knowledge/graph", headers=auth)
    assert empty.status_code == 422

    settings = get_settings()
    monkeypatch.setattr(settings, "wikidata_max_items_per_request", 1)
    limited = _graph(client, auth, topic="Saurischia", up_depth=2, down_depth=2)
    assert limited.status_code == 200
    assert limited.json()["incomplete"] is True
    assert limited.json()["focus_node_id"] == SAURISCHIA


def test_wikidata_client_retries_a_rate_limit_and_sends_a_user_agent():
    calls = {"n": 0}

    def handler(request: httpx.Request) -> httpx.Response:
        calls["n"] += 1
        assert request.headers["user-agent"].startswith("AdaptiveMastery/")
        if calls["n"] == 1:
            return httpx.Response(429, headers={"Retry-After": "0"}, json={"error": {"code": "ratelimited"}})
        return httpx.Response(200, json={"search": [], "success": 1})

    client = WikidataClient(transport=httpx.MockTransport(handler), sleeper=lambda _delay: None)
    try:
        payload = client.get({"action": "wbsearchentities", "search": "dinosaur"})
    finally:
        client.close()
    assert calls["n"] == 2
    assert payload["success"] == 1
    assert parse_qid("http://www.wikidata.org/entity/Q430") == 430
