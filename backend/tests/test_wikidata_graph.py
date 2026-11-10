from datetime import timedelta

import httpx
from sqlalchemy import distinct
from sqlmodel import func, select

from app.core.config import get_settings
from app.core.time import utcnow
from app.features.knowledge_graph.graph import load_knowledge_graph
from app.features.knowledge_graph.node_models import KnowledgeNode, KnowledgeRequest, KnowledgeRequestNode
from app.features.knowledge_graph.wikidata import WikiDataError, WikiEntity, parse_qid
from app.features.knowledge_graph.wikipedia_related import RelatedHit, WikipediaError

LIFE = 7239
ANIMALS = 20
REPTILES = 30
DINOSAURS = 430
SAURISCHIA = 6
ORNITHISCHIA = 7
GENERA = 8
TOYS = 11
COLORS = 10
MESOZOIC = 500
PALAEONTOLOGY = 501
DRACOHORS = 99


def _item(qid, title, *, subclass=(), taxon=(), instance=(), sitelinks=1, description=None, enwiki=None):
    return WikiEntity(
        qid=qid,
        title=title,
        description=description,
        enwiki_title=enwiki or title,
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

    def children(self, qid, *, taxon=False):
        self.calls.append(("children", qid, taxon))
        if qid in self.fail_downstream:
            raise WikiDataError("downstream failed")
        if qid not in self.items:
            raise WikiDataError("missing item")
        return list(self.child_map.get(qid, []))


class FakeWikipedia:
    def __init__(self, related=None):
        self.related_map = {key.lower(): list(value) for key, value in (related or {}).items()}
        self.calls: list[tuple] = []
        self.fail = False

    def close(self):
        return None

    def related(self, enwiki_title, *, limit=8):
        self.calls.append(("related", enwiki_title, limit))
        if self.fail:
            raise WikipediaError("wikipedia failed")
        hits = self.related_map.get(enwiki_title.lower(), [])
        return hits[:limit]


def _dinosaurs():
    return FakeWikidata(
        [
            _item(LIFE, "organism", sitelinks=40),
            _item(ANIMALS, "animal", taxon=(LIFE,), subclass=(LIFE,), sitelinks=80),
            _item(REPTILES, "reptile", taxon=(ANIMALS,), subclass=(ANIMALS,), sitelinks=60),
            _item(
                DINOSAURS,
                "dinosaur",
                taxon=(DRACOHORS,),
                subclass=(REPTILES, ANIMALS),
                sitelinks=50,
                enwiki="Dinosaur",
            ),
            _item(DRACOHORS, "Dracohors", taxon=(REPTILES,), sitelinks=2),
            _item(SAURISCHIA, "Saurischia", taxon=(DINOSAURS,), sitelinks=30),
            _item(ORNITHISCHIA, "Ornithischia", taxon=(DINOSAURS,), sitelinks=28),
            _item(GENERA, "dinosaur genera", taxon=(SAURISCHIA,), sitelinks=5),
            _item(TOYS, "dinosaur toys", sitelinks=3, description="toys shaped like dinosaurs"),
            _item(COLORS, "dinosaur colors", sitelinks=2, description="coloration"),
            _item(MESOZOIC, "Mesozoic", sitelinks=40, enwiki="Mesozoic"),
            _item(PALAEONTOLOGY, "paleontology", sitelinks=35, enwiki="Paleontology"),
        ],
        children={DINOSAURS: [SAURISCHIA, ORNITHISCHIA], SAURISCHIA: [GENERA]},
    )


def _wikipedia():
    return FakeWikipedia(
        {
            "Dinosaur": [
                RelatedHit(title="Mesozoic", qid=MESOZOIC),
                RelatedHit(title="Paleontology", qid=PALAEONTOLOGY),
            ]
        }
    )


def _graph(client, auth, **params):
    query = "&".join(f"{key}={value}" for key, value in params.items() if value is not None)
    path = "/api/v1/knowledge/graph" + (f"?{query}" if query else "")
    return client.get(path, headers=auth)


def test_parse_qid():
    assert parse_qid("Q430") == 430
    assert parse_qid("https://www.wikidata.org/entity/Q430") == 430
    assert parse_qid(None) is None


def test_dinosaurs_resolve_parents_children_and_related(client, auth, session, monkeypatch):
    wiki = _dinosaurs()
    related = _wikipedia()

    def load(session, **kwargs):
        kwargs.setdefault("wikidata", wiki)
        kwargs.setdefault("wikipedia", related)
        return load_knowledge_graph(session, **kwargs)

    monkeypatch.setattr("app.api.v1.router.load_knowledge_graph", load)

    response = _graph(client, auth, topic="dinosaurs", up_depth=2, down_depth=1, cloud_radius=1)
    assert response.status_code == 200
    payload = response.json()
    assert payload["focus_node_id"] == DINOSAURS
    assert payload["request_id"]
    by_id = {node["id"]: node for node in payload["nodes"]}
    assert REPTILES in by_id
    assert ANIMALS in by_id
    assert SAURISCHIA in by_id
    assert ORNITHISCHIA in by_id
    assert MESOZOIC in by_id
    assert PALAEONTOLOGY in by_id
    assert by_id[REPTILES]["depth"] == -1
    assert by_id[ANIMALS]["depth"] == -2
    assert by_id[SAURISCHIA]["depth"] == 1
    assert by_id[MESOZOIC]["kind"] == "related"
    assert by_id[DINOSAURS]["distance"] == 0
    assert by_id[SAURISCHIA]["distance"] == 1
    types = {(edge["source"], edge["target"], edge["type"]) for edge in payload["edges"]}
    assert (REPTILES, DINOSAURS, "subclass_of") in types
    assert (DINOSAURS, SAURISCHIA, "parent_taxon") in types
    assert (DINOSAURS, MESOZOIC, "related_to") in types
    assert DRACOHORS not in by_id

    stored = session.exec(select(KnowledgeRequestNode)).all()
    assert {row.qid for row in stored} == set(by_id)
    assert session.exec(select(func.count()).select_from(KnowledgeRequest)).one() == 1


def test_clear_winner_skips_ambiguous_chooser(client, auth, monkeypatch):
    wiki = FakeWikidata(
        [
            _item(DINOSAURS, "dinosaur", subclass=(REPTILES,), sitelinks=50),
            _item(REPTILES, "reptile", sitelinks=60),
            _item(TOYS, "dinosaur toys", sitelinks=3, description="toys"),
        ],
        children={DINOSAURS: []},
    )
    monkeypatch.setattr(
        "app.api.v1.router.load_knowledge_graph",
        lambda session, **kwargs: load_knowledge_graph(session, wikidata=wiki, wikipedia=FakeWikipedia(), **kwargs),
    )
    response = _graph(client, auth, topic="dinosaur")
    assert response.status_code == 200
    assert response.json()["focus_node_id"] == DINOSAURS


def test_ambiguous_includes_descriptions(client, auth, monkeypatch):
    wiki = FakeWikidata(
        [
            _item(TOYS, "Dinosaur", sitelinks=5, description="toys shaped like dinosaurs"),
            _item(COLORS, "Dinosaur", sitelinks=4, description="coloration"),
        ]
    )
    monkeypatch.setattr(
        "app.api.v1.router.load_knowledge_graph",
        lambda session, **kwargs: load_knowledge_graph(session, wikidata=wiki, wikipedia=FakeWikipedia(), **kwargs),
    )
    response = _graph(client, auth, topic="Dinosaur")
    assert response.status_code == 409
    candidates = response.json()["details"]["candidates"]
    assert {row["wikidata_qid"] for row in candidates} == {TOYS, COLORS}
    assert all(row.get("description") for row in candidates)


def test_resume_latest_request(client, auth, other_auth, session, monkeypatch):
    wiki = _dinosaurs()
    related = _wikipedia()
    monkeypatch.setattr(
        "app.api.v1.router.load_knowledge_graph",
        lambda session, **kwargs: load_knowledge_graph(
            session, wikidata=wiki, wikipedia=related, **kwargs
        ),
    )
    first = _graph(client, auth, topic="dinosaurs", up_depth=1, down_depth=1, cloud_radius=1)
    assert first.status_code == 200
    resumed = _graph(client, auth)
    assert resumed.status_code == 200
    assert resumed.json()["focus_node_id"] == DINOSAURS

    empty = _graph(client, other_auth)
    assert empty.status_code == 200
    assert empty.json()["focus_node_id"] is None
    assert empty.json()["nodes"] == []


def test_focus_qid_opens_child_without_duplicating_nodes(client, auth, session, monkeypatch):
    wiki = _dinosaurs()
    related = _wikipedia()
    monkeypatch.setattr(
        "app.api.v1.router.load_knowledge_graph",
        lambda session, **kwargs: load_knowledge_graph(
            session, wikidata=wiki, wikipedia=related, **kwargs
        ),
    )
    _graph(client, auth, topic="dinosaurs", up_depth=1, down_depth=1, cloud_radius=1)
    before = set(session.exec(select(KnowledgeNode.qid)).all())
    focused = _graph(client, auth, focus_qid=SAURISCHIA, up_depth=1, down_depth=1, cloud_radius=1)
    assert focused.status_code == 200
    assert focused.json()["focus_node_id"] == SAURISCHIA
    after = set(session.exec(select(KnowledgeNode.qid)).all())
    assert before.issubset(after)
    assert GENERA in after
    assert len(after) == session.exec(select(func.count(distinct(KnowledgeNode.qid))).select_from(KnowledgeNode)).one()


def test_cache_skips_refetch(client, auth, monkeypatch):
    wiki = _dinosaurs()
    related = _wikipedia()
    monkeypatch.setattr(
        "app.api.v1.router.load_knowledge_graph",
        lambda session, **kwargs: load_knowledge_graph(
            session, wikidata=wiki, wikipedia=related, **kwargs
        ),
    )
    _graph(client, auth, topic="dinosaurs", up_depth=1, down_depth=1, cloud_radius=1)
    before = len(wiki.calls)
    related_before = len(related.calls)
    _graph(client, auth, focus_qid=DINOSAURS, up_depth=1, down_depth=1, cloud_radius=1)
    assert len(wiki.calls) == before
    assert len(related.calls) == related_before


def test_stale_cache_refetches(client, auth, session, monkeypatch):
    wiki = _dinosaurs()
    related = _wikipedia()
    monkeypatch.setattr(
        "app.api.v1.router.load_knowledge_graph",
        lambda session, **kwargs: load_knowledge_graph(
            session, wikidata=wiki, wikipedia=related, **kwargs
        ),
    )
    _graph(client, auth, topic="dinosaurs", up_depth=1, down_depth=1, cloud_radius=1)
    node = session.get(KnowledgeNode, DINOSAURS)
    node.upstream_fetched_at = utcnow() - timedelta(days=get_settings().wikidata_cache_ttl_days + 1)
    node.downstream_fetched_at = node.upstream_fetched_at
    node.related_fetched_at = node.upstream_fetched_at
    session.add(node)
    session.commit()
    before = len([call for call in wiki.calls if call[0] == "children"])
    _graph(client, auth, focus_qid=DINOSAURS, up_depth=1, down_depth=1, cloud_radius=1)
    after = len([call for call in wiki.calls if call[0] == "children"])
    assert after > before


def test_related_limit_scales_with_cloud_radius(client, auth, monkeypatch):
    wiki = _dinosaurs()
    related = _wikipedia()
    monkeypatch.setattr(
        "app.api.v1.router.load_knowledge_graph",
        lambda session, **kwargs: load_knowledge_graph(
            session, wikidata=wiki, wikipedia=related, **kwargs
        ),
    )
    _graph(client, auth, topic="dinosaurs", cloud_radius=2)
    assert related.calls[-1] == ("related", "Dinosaur", 16)


def test_wikipedia_morelike_transport_maps_qid(monkeypatch):
    from app.features.knowledge_graph.wikipedia_related import WikipediaRelatedClient

    def handler(request: httpx.Request) -> httpx.Response:
        if b"list=search" in request.url.query or "list=search" in str(request.url):
            return httpx.Response(
                200,
                json={"query": {"search": [{"title": "Mesozoic"}, {"title": "Paleontology"}]}},
            )
        return httpx.Response(
            200,
            json={
                "query": {
                    "pages": {
                        "1": {"title": "Mesozoic", "pageprops": {"wikibase_item": "Q500"}, "description": "era"},
                        "2": {"title": "Paleontology", "pageprops": {"wikibase_item": "Q501"}},
                    }
                }
            },
        )

    transport = httpx.MockTransport(handler)
    client = WikipediaRelatedClient(transport=transport, sleeper=lambda _: None)
    hits = client.related("Dinosaur", limit=8)
    client.close()
    assert [hit.qid for hit in hits] == [500, 501]
