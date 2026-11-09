from datetime import timedelta

import httpx
from sqlalchemy import distinct
from sqlmodel import func, select

from app.core.config import get_settings
from app.core.time import utcnow
from app.features.knowledge_graph.category_models import KnowledgeCategory, KnowledgeGraphRequest
from app.features.knowledge_graph.models import Concept
from app.features.knowledge_graph.service import shared_graph
from app.features.knowledge_graph.wikipedia import WikiError, WikipediaClient, display_title

SCIENCE = 1
PALEONTOLOGY = 2
BIOLOGY = 3
DINOSAURS = 4
CLASSIFICATION = 5
SAURISCHIA = 6
ORNITHISCHIA = 7
GENERA = 8
HIDDEN = 9
COLORS = 10
TOYS = 11


class FakeWiki:
    def __init__(self, pages, parents=None, children=None, hidden=None, articles=None, article_categories=None):
        self.pages = dict(pages)
        self.parents = {key: list(value) for key, value in (parents or {}).items()}
        self.children = {key: list(value) for key, value in (children or {}).items()}
        self.hidden = set(hidden or [])
        self.articles = dict(articles or {})
        self.article_categories = {key: list(value) for key, value in (article_categories or {}).items()}
        self.missing_exact: set[str] = set()
        self.fail_upstream: set[int] = set()
        self.fail_downstream: set[int] = set()
        self.parent_split: dict[int, int] = {}
        self.child_split: dict[int, int] = {}
        self.calls: list[dict] = []

    def get(self, params):
        self.calls.append(dict(params))
        if params.get("list") == "search":
            return self._search(params)
        if params.get("list") == "categorymembers":
            return self._members(params)
        prop = str(params.get("prop") or "")
        if "categories" in prop:
            return self._category_prop(params)
        if "titles" in params:
            return self._by_titles(str(params["titles"]))
        if "pageids" in params:
            return self._by_ids(str(params["pageids"]))
        raise AssertionError(params)

    def _search(self, params):
        namespace = int(params["srnamespace"])
        query = str(params["srsearch"]).lower()
        limit = int(params["srlimit"])
        if namespace == 0:
            article_id = self.articles.get(query)
            if article_id is None:
                return {"query": {"search": []}}
            return {"query": {"search": [{"pageid": article_id, "title": query.title()}]}}
        hits = [
            {"pageid": page_id, "ns": 14, "title": f"Category:{title}"}
            for page_id, title in self.pages.items()
            if query in title.lower() and page_id not in self.hidden
        ]
        hits.sort(key=lambda hit: hit["title"])
        return {"query": {"search": hits[:limit]}}

    def _members(self, params):
        page_id = int(params["cmpageid"])
        if page_id in self.fail_downstream:
            raise WikiError("downstream failed")
        if page_id not in self.pages:
            raise WikiError("missing category")
        child_ids = list(self.children.get(page_id, []))
        offset = int(params.get("cmcontinue") or 0)
        split = self.child_split.get(page_id)
        if split and offset == 0 and split < len(child_ids):
            return {
                "continue": {"cmcontinue": str(split), "continue": "cmcontinue"},
                "query": {"categorymembers": [self._member(page) for page in child_ids[:split]]},
            }
        return {"query": {"categorymembers": [self._member(page) for page in child_ids[offset:]]}}

    def _member(self, page_id):
        return {"pageid": page_id, "ns": 14, "title": f"Category:{self.pages[page_id]}"}

    def _category_prop(self, params):
        page_id = int(str(params["pageids"]).split("|")[0])
        if page_id in self.fail_upstream:
            raise WikiError("upstream failed")
        if page_id in self.article_categories:
            parent_ids = self.article_categories[page_id]
            return {
                "query": {
                    "pages": [
                        {
                            "pageid": page_id,
                            "ns": 0,
                            "title": "Article",
                            "categories": [{"ns": 14, "title": f"Category:{self.pages[parent]}"} for parent in parent_ids],
                        }
                    ]
                }
            }
        if page_id not in self.pages:
            return {"query": {"pages": [{"pageid": page_id, "missing": True}]}}
        parent_ids = list(self.parents.get(page_id, []))
        offset = int(params.get("clcontinue") or 0)
        split = self.parent_split.get(page_id)
        if split and offset == 0 and split < len(parent_ids):
            return {
                "continue": {"clcontinue": str(split), "continue": "clcontinue"},
                "query": {"pages": [self._with_parents(page_id, parent_ids[:split])]},
            }
        return {"query": {"pages": [self._with_parents(page_id, parent_ids[offset:])]}}

    def _with_parents(self, page_id, parent_ids):
        page = self._info(page_id)
        page["categories"] = [{"ns": 14, "title": f"Category:{self.pages[parent]}"} for parent in parent_ids]
        return page

    def _by_titles(self, raw):
        titles = raw.split("|")
        if len(titles) == 1 and display_title(titles[0]).lower() in self.missing_exact:
            return {"query": {"pages": [{"title": titles[0], "missing": True}]}}
        return {"query": {"pages": [self._page_for_title(title) for title in titles]}}

    def _page_for_title(self, title):
        name = display_title(title).lower()
        for page_id, label in self.pages.items():
            if label.lower() == name:
                return self._info(page_id)
        return {"title": title, "missing": True}

    def _by_ids(self, raw):
        pages = []
        for part in raw.split("|"):
            if not part:
                continue
            page_id = int(part)
            pages.append(self._info(page_id) if page_id in self.pages else {"pageid": page_id, "missing": True})
        return {"query": {"pages": pages}}

    def _info(self, page_id):
        page = {
            "pageid": page_id,
            "ns": 14,
            "title": f"Category:{self.pages[page_id]}",
            "extract": f"{self.pages[page_id]} is a category.",
        }
        if page_id in self.hidden:
            page["pageprops"] = {"hiddencat": ""}
        return page


def _install(monkeypatch, fake: FakeWiki) -> None:
    monkeypatch.setattr("app.features.knowledge_graph.categories.WikipediaClient", lambda: fake)


def _dinosaur_wiki() -> FakeWiki:
    return FakeWiki(
        pages={
            SCIENCE: "Science",
            PALEONTOLOGY: "Paleontology",
            BIOLOGY: "Biology",
            DINOSAURS: "Dinosaurs",
            CLASSIFICATION: "Dinosaur classification",
            SAURISCHIA: "Saurischia",
            ORNITHISCHIA: "Ornithischia",
            GENERA: "Dinosaur genera",
            HIDDEN: "Dinosaur maintenance",
            COLORS: "Dinosaur colors",
            TOYS: "Dinosaur toys",
        },
        parents={
            PALEONTOLOGY: [SCIENCE],
            DINOSAURS: [PALEONTOLOGY, BIOLOGY],
            CLASSIFICATION: [DINOSAURS],
            SAURISCHIA: [CLASSIFICATION],
            ORNITHISCHIA: [CLASSIFICATION],
            GENERA: [SAURISCHIA],
        },
        children={
            SCIENCE: [PALEONTOLOGY],
            PALEONTOLOGY: [DINOSAURS],
            BIOLOGY: [DINOSAURS],
            DINOSAURS: [CLASSIFICATION, HIDDEN],
            CLASSIFICATION: [SAURISCHIA, ORNITHISCHIA],
            SAURISCHIA: [GENERA],
        },
        hidden={HIDDEN},
    )


def _graph(client, auth, **params):
    response = client.get("/api/v1/knowledge/graph", headers=auth, params=params)
    return response


def _parent_calls(fake: FakeWiki, page_id: int) -> list[dict]:
    return [
        call
        for call in fake.calls
        if str(call.get("prop") or "") == "categories" and str(call.get("pageids")) == str(page_id)
    ]


def test_dinosaurs_walks_two_levels_skips_hidden_and_keeps_multiple_parents(client, auth, monkeypatch):
    fake = _dinosaur_wiki()
    fake.parent_split[DINOSAURS] = 1
    fake.child_split[CLASSIFICATION] = 1
    _install(monkeypatch, fake)

    response = _graph(client, auth, topic="Dinosaurs", up_depth=2, down_depth=2)
    assert response.status_code == 200
    body = response.json()
    assert body["focus_node_id"] == DINOSAURS
    assert body["incomplete"] is False
    titles = {node["title"]: node for node in body["nodes"]}
    assert titles["Science"]["depth"] == -2
    assert titles["Paleontology"]["depth"] == -1
    assert titles["Biology"]["depth"] == -1
    assert titles["Dinosaurs"]["depth"] == 0
    assert titles["Dinosaur classification"]["depth"] == 1
    assert titles["Saurischia"]["depth"] == 2
    assert titles["Ornithischia"]["depth"] == 2
    assert "Dinosaur maintenance" not in titles
    assert "Dinosaur genera" not in titles
    edges = {(edge["source"], edge["target"], edge["type"]) for edge in body["edges"]}
    assert (PALEONTOLOGY, DINOSAURS, "parent_child") in edges
    assert (BIOLOGY, DINOSAURS, "parent_child") in edges
    assert (SCIENCE, PALEONTOLOGY, "parent_child") in edges
    assert (DINOSAURS, CLASSIFICATION, "parent_child") in edges
    assert (CLASSIFICATION, SAURISCHIA, "parent_child") in edges
    assert (CLASSIFICATION, ORNITHISCHIA, "parent_child") in edges
    assert all(edge[0] != HIDDEN and edge[1] != HIDDEN for edge in edges)
    assert any(call.get("clshow") == "!hidden" for call in fake.calls)
    assert any("clcontinue" in call for call in fake.calls)
    assert any("cmcontinue" in call for call in fake.calls)


def test_cycles_stop_and_a_second_search_reuses_the_same_rows(client, auth, other_auth, session, monkeypatch):
    fake = FakeWiki(
        pages={1: "Alpha", 2: "Beta"},
        parents={1: [2], 2: [1]},
        children={1: [2], 2: [1]},
    )
    _install(monkeypatch, fake)
    first = _graph(client, auth, topic="Alpha", up_depth=2, down_depth=2)
    assert first.status_code == 200
    body = first.json()
    assert {node["id"] for node in body["nodes"]} == {1, 2}
    assert len(body["nodes"]) == 2
    assert fake.calls
    recorded = len(fake.calls)
    fake.calls.clear()

    second = _graph(client, other_auth, topic="beta", up_depth=2, down_depth=2)
    assert second.status_code == 200
    assert second.json()["focus_node_id"] == 2
    assert fake.calls == []
    assert recorded > 0
    count = session.exec(select(func.count()).select_from(KnowledgeCategory)).one()
    distinct_ids = session.exec(select(func.count(distinct(KnowledgeCategory.wikipedia_page_id)))).one()
    assert count == distinct_ids == 2
    requests = session.exec(select(KnowledgeGraphRequest)).all()
    assert len(requests) == 2


def test_overlapping_topic_fetches_only_the_missing_branch(client, auth, other_auth, session, monkeypatch):
    fake = _dinosaur_wiki()
    _install(monkeypatch, fake)
    opened = _graph(client, auth, topic="Category:Dinosaurs", up_depth=2, down_depth=2)
    assert opened.status_code == 200
    assert session.exec(select(KnowledgeCategory).where(KnowledgeCategory.wikipedia_page_id == DINOSAURS)).first() is not None
    fake.calls.clear()

    focused = _graph(client, other_auth, category_id=SAURISCHIA, up_depth=2, down_depth=2)
    assert focused.status_code == 200
    body = focused.json()
    assert body["focus_node_id"] == SAURISCHIA
    titles = {node["title"] for node in body["nodes"]}
    assert "Dinosaur genera" in titles
    assert "Dinosaurs" in titles
    assert _parent_calls(fake, DINOSAURS) == []
    assert _parent_calls(fake, SAURISCHIA)
    rows = session.exec(select(KnowledgeCategory.wikipedia_page_id)).all()
    assert len(rows) == len(set(rows))
    again = _graph(client, auth, category_id=SAURISCHIA, up_depth=2, down_depth=2)
    assert again.status_code == 200
    assert session.exec(select(func.count()).select_from(KnowledgeCategory)).one() == len(set(rows))


def test_failed_fetch_stays_incomplete_and_a_stale_direction_is_read_again(client, auth, session, monkeypatch):
    fake = _dinosaur_wiki()
    fake.fail_upstream.add(DINOSAURS)
    _install(monkeypatch, fake)
    partial = _graph(client, auth, topic="Dinosaurs", up_depth=1, down_depth=0)
    assert partial.status_code == 200
    assert partial.json()["incomplete"] is True
    assert partial.json()["nodes"] == [{"id": DINOSAURS, "title": "Dinosaurs", "depth": 0}]
    assert partial.json()["edges"] == []
    stored = session.exec(select(KnowledgeCategory).where(KnowledgeCategory.wikipedia_page_id == DINOSAURS)).one()
    assert stored.upstream_complete is False

    fake.fail_upstream.clear()
    restored = _graph(client, auth, topic="Dinosaurs", up_depth=1, down_depth=0)
    assert restored.status_code == 200
    assert restored.json()["incomplete"] is False
    assert {edge["source"] for edge in restored.json()["edges"]} == {PALEONTOLOGY, BIOLOGY}

    session.expire_all()
    category = session.exec(select(KnowledgeCategory).where(KnowledgeCategory.wikipedia_page_id == DINOSAURS)).one()
    category.upstream_fetched_at = utcnow() - timedelta(days=31)
    session.add(category)
    session.commit()
    fake.calls.clear()
    stale = _graph(client, auth, topic="Dinosaurs", up_depth=1, down_depth=0)
    assert stale.status_code == 200
    assert _parent_calls(fake, DINOSAURS)

    session.expire_all()
    category = session.exec(select(KnowledgeCategory).where(KnowledgeCategory.wikipedia_page_id == DINOSAURS)).one()
    assert category.upstream_complete is True
    fake.calls.clear()
    fresh = _graph(client, auth, topic="Dinosaurs", up_depth=1, down_depth=0)
    assert fresh.status_code == 200
    assert _parent_calls(fake, DINOSAURS) == []


def test_ambiguous_search_article_fallback_and_preserved_concepts(client, auth, session, monkeypatch, user):
    fake = _dinosaur_wiki()
    fake.missing_exact.add("dinosaur colors")
    _install(monkeypatch, fake)
    ambiguous = _graph(client, auth, topic="dinosaur")
    assert ambiguous.status_code == 409
    candidates = {item["title"] for item in ambiguous.json()["details"]["candidates"]}
    assert "Dinosaur colors" in candidates
    assert "Dinosaur toys" in candidates
    assert session.exec(select(func.count()).select_from(KnowledgeCategory)).one() == 0

    article = FakeWiki(
        pages={DINOSAURS: "Dinosaurs", PALEONTOLOGY: "Paleontology"},
        parents={DINOSAURS: [PALEONTOLOGY], PALEONTOLOGY: []},
        children={DINOSAURS: [], PALEONTOLOGY: [DINOSAURS]},
        articles={"raptor": 900},
        article_categories={900: [DINOSAURS]},
    )
    article.missing_exact.add("raptor")
    _install(monkeypatch, article)
    graph = shared_graph(session)
    kept = Concept(
        origin_graph_id=graph.id,
        title="Dinosaurs",
        summary="Original summary",
        explanation="Keep this mastery",
        level=7,
        canonical_key="dinosaurs",
    )
    other = Concept(
        origin_graph_id=graph.id,
        title="Imaginary topic",
        summary="Leave me",
        explanation="Not a wikipedia category",
        level=3,
        canonical_key="imaginary-topic",
    )
    session.add(graph)
    session.add(kept)
    session.add(other)
    session.commit()
    kept_id = kept.id
    other_id = other.id

    matched = _graph(client, auth, topic="raptor", up_depth=1, down_depth=0)
    assert matched.status_code == 200
    assert matched.json()["focus_node_id"] == DINOSAURS
    assert all(node["title"] != "Imaginary topic" for node in matched.json()["nodes"])

    session.expire_all()
    kept = session.get(Concept, kept_id)
    other = session.get(Concept, other_id)
    assert kept.explanation == "Keep this mastery"
    assert kept.summary == "Original summary"
    assert kept.level == 7
    assert kept.title == "Dinosaurs"
    assert kept.knowledge_category_id is not None
    assert other.knowledge_category_id is None
    assert other.explanation == "Not a wikipedia category"
    linked = session.get(KnowledgeCategory, kept.knowledge_category_id)
    assert linked.wikipedia_page_id == DINOSAURS


def test_missing_topic_and_category_budget(client, auth, monkeypatch):
    fake = _dinosaur_wiki()
    _install(monkeypatch, fake)
    missing = _graph(client, auth, topic="No such category")
    assert missing.status_code == 404
    empty = client.get("/api/v1/knowledge/graph", headers=auth)
    assert empty.status_code == 422

    settings = get_settings()
    monkeypatch.setattr(settings, "wikipedia_max_categories_per_request", 1)
    limited = _graph(client, auth, topic="Dinosaurs", up_depth=2, down_depth=2)
    assert limited.status_code == 200
    assert limited.json()["incomplete"] is True
    assert limited.json()["focus_node_id"] == DINOSAURS


def test_wikipedia_client_retries_a_rate_limit_and_sends_a_user_agent():
    calls = {"n": 0}

    def handler(request: httpx.Request) -> httpx.Response:
        calls["n"] += 1
        assert request.headers["user-agent"].startswith("AdaptiveMastery/")
        if calls["n"] == 1:
            return httpx.Response(429, headers={"Retry-After": "0"}, json={"error": {"code": "ratelimited"}})
        return httpx.Response(200, json={"batchcomplete": True, "query": {"pages": []}})

    client = WikipediaClient(transport=httpx.MockTransport(handler), sleeper=lambda _delay: None)
    try:
        payload = client.get({"action": "query", "titles": "Category:Dinosaurs"})
    finally:
        client.close()
    assert calls["n"] == 2
    assert payload["batchcomplete"] is True
