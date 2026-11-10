"""Read class and taxon structure from Wikidata."""

from __future__ import annotations

import time
from collections.abc import Callable
from dataclasses import dataclass

import httpx

from app.core.config import get_settings

USER_AGENT = "AdaptiveMastery/1.0 (https://github.com/dezwier/learnfromai; knowledge graph)"
_RETRY_CODES = {"ratelimited", "maxlag"}
_ENTITY_BATCH = 20
_CHILD_LIMIT = 80

# Pedagogical ceilings. Never walk parents of these, never climb to entity (Q35120).
DOMAIN_ROOT_QIDS: frozenset[int] = frozenset(
    {
        7239,  # organism / Life
        223557,  # physical object
        2221906,  # geographic location
        215627,  # person
        43229,  # organization
        1190554,  # occurrence
        386724,  # work
        11862829,  # academic discipline
        11016,  # technology
        34770,  # language
        21484471,  # abstract object
    }
)

_SKIP_INSTANCE = frozenset(
    {
        4167836,  # Wikimedia category
        4167410,  # Wikimedia disambiguation page
        13406463,  # Wikimedia list article
        11266439,  # Wikimedia template
        14204246,  # Wikimedia project page
    }
)


class WikiDataError(Exception):
    """Wikidata could not return a usable response."""


@dataclass(frozen=True)
class WikiEntity:
    qid: int
    title: str
    description: str | None
    sitelinks: int
    subclass_of: tuple[int, ...]
    parent_taxon: tuple[int, ...]
    instance_of: tuple[int, ...]

    @property
    def skipped(self) -> bool:
        return bool(set(self.instance_of) & _SKIP_INSTANCE) or _junk_title(self.title)


class WikidataClient:
    """HTTP client for Wikidata api.php and SPARQL."""

    def __init__(self, *, transport: httpx.BaseTransport | None = None, sleeper: Callable[[float], None] | None = None):
        self._settings = get_settings()
        self._transport = transport
        self._sleeper = sleeper or time.sleep
        self._http: httpx.Client | None = None

    def close(self) -> None:
        if self._http is not None:
            self._http.close()
            self._http = None

    def _connection(self) -> httpx.Client:
        if self._http is None:
            self._http = httpx.Client(
                timeout=self._settings.wikidata_timeout_seconds,
                headers={"User-Agent": self._settings.wikidata_user_agent or USER_AGENT},
                transport=self._transport,
                follow_redirects=True,
            )
        return self._http

    def get(self, params: dict[str, object]) -> dict:
        query = {"format": "json"}
        for key, value in params.items():
            if value is None:
                continue
            query[str(key)] = value if isinstance(value, str) else str(value)
        return self._request("GET", self._settings.wikidata_api_url, params=query)

    def sparql(self, query: str) -> dict:
        return self._request(
            "GET",
            self._settings.wikidata_sparql_url,
            params={"query": query, "format": "json"},
        )

    def _request(self, method: str, url: str, *, params: dict[str, object]) -> dict:
        client = self._connection()
        last_error: Exception | None = None
        for attempt in range(4):
            try:
                response = client.request(method, url, params=params)
            except httpx.HTTPError as exc:
                last_error = exc
                if attempt == 3:
                    break
                self._sleeper(min(2.0, 0.4 * (attempt + 1)))
                continue
            if response.status_code == 429 or response.status_code >= 500:
                last_error = WikiDataError(f"Wikidata returned HTTP {response.status_code}")
                if attempt == 3:
                    break
                self._sleeper(_retry_delay(response, attempt))
                continue
            try:
                response.raise_for_status()
                payload = response.json()
            except (httpx.HTTPError, ValueError) as exc:
                last_error = exc
                if attempt == 3:
                    break
                self._sleeper(min(2.0, 0.4 * (attempt + 1)))
                continue
            error = payload.get("error") if isinstance(payload, dict) else None
            if isinstance(error, dict) and str(error.get("code") or "") in _RETRY_CODES:
                last_error = WikiDataError(str(error.get("info") or error.get("code")))
                if attempt == 3:
                    break
                self._sleeper(_retry_delay(response, attempt))
                continue
            if isinstance(error, dict):
                raise WikiDataError(str(error.get("info") or error.get("code") or "Wikidata request failed"))
            if not isinstance(payload, dict):
                raise WikiDataError("Wikidata returned an unexpected payload")
            return payload
        raise WikiDataError("Wikidata could not be reached") from last_error

    def search(self, name: str, *, limit: int = 8) -> list[WikiEntity]:
        payload = self.get(
            {
                "action": "wbsearchentities",
                "search": name,
                "language": "en",
                "uselang": "en",
                "type": "item",
                "limit": limit,
            }
        )
        qids: list[int] = []
        for hit in payload.get("search") or []:
            qid = parse_qid(hit.get("id"))
            if qid is not None:
                qids.append(qid)
        return [item for item in self.entities(qids) if not item.skipped]

    def entities(self, qids: list[int]) -> list[WikiEntity]:
        found: list[WikiEntity] = []
        unique = list(dict.fromkeys(qids))
        for start in range(0, len(unique), _ENTITY_BATCH):
            chunk = unique[start : start + _ENTITY_BATCH]
            if not chunk:
                continue
            payload = self.get(
                {
                    "action": "wbgetentities",
                    "ids": "|".join(f"Q{qid}" for qid in chunk),
                    "props": "labels|descriptions|claims|sitelinks",
                    "languages": "en",
                    "languagefallback": "1",
                }
            )
            entities = payload.get("entities") or {}
            if not isinstance(entities, dict):
                continue
            for raw in entities.values():
                item = parse_entity(raw)
                if item is not None:
                    found.append(item)
        return found

    def children(self, qid: int) -> list[int]:
        query = (
            "SELECT DISTINCT ?child WHERE {"
            " VALUES ?rel { wdt:P279 wdt:P171 }"
            f" ?child ?rel wd:Q{qid} ."
            " }"
            f" LIMIT {_CHILD_LIMIT}"
        )
        payload = self.sparql(query)
        bindings = ((payload.get("results") or {}).get("bindings")) or []
        qids: list[int] = []
        for row in bindings:
            if not isinstance(row, dict):
                continue
            child = row.get("child") or {}
            qid_value = parse_qid(child.get("value") if isinstance(child, dict) else None)
            if qid_value is not None:
                qids.append(qid_value)
        return list(dict.fromkeys(qids))


def parse_qid(value: object) -> int | None:
    if value is None:
        return None
    if isinstance(value, int):
        return value if value > 0 else None
    text = str(value).strip()
    if "/" in text:
        text = text.rsplit("/", 1)[-1]
    if text[:1] in {"Q", "q"} and text[1:].isdigit():
        return int(text[1:])
    if text.isdigit():
        return int(text)
    return None


def parse_entity(raw: object) -> WikiEntity | None:
    if not isinstance(raw, dict) or raw.get("missing") is not None:
        return None
    qid = parse_qid(raw.get("id"))
    if qid is None:
        return None
    title = _label(raw) or f"Q{qid}"
    description = _description(raw)
    sitelinks = raw.get("sitelinks") or {}
    count = len(sitelinks) if isinstance(sitelinks, dict) else 0
    claims = raw.get("claims") if isinstance(raw.get("claims"), dict) else {}
    return WikiEntity(
        qid=qid,
        title=title,
        description=description,
        sitelinks=count,
        subclass_of=tuple(_claim_qids(claims, "P279")),
        parent_taxon=tuple(_claim_qids(claims, "P171")),
        instance_of=tuple(_claim_qids(claims, "P31")),
    )


def preferred_parent_qids(entity: WikiEntity) -> list[int]:
    if entity.qid in DOMAIN_ROOT_QIDS:
        return []
    if entity.parent_taxon:
        return [qid for qid in entity.parent_taxon if qid != entity.qid]
    return [qid for qid in entity.subclass_of if qid != entity.qid]


def pick_parent(entity: WikiEntity, parents: list[WikiEntity]) -> WikiEntity | None:
    usable = [item for item in parents if not item.skipped and item.qid != entity.qid]
    if not usable:
        return None
    preferred = set(preferred_parent_qids(entity))
    if preferred:
        usable = [item for item in usable if item.qid in preferred] or usable
    roots = [item for item in usable if item.qid in DOMAIN_ROOT_QIDS]
    pool = roots or usable
    return max(pool, key=lambda item: (item.qid in DOMAIN_ROOT_QIDS, item.sitelinks, -item.qid))


def _label(raw: dict) -> str | None:
    labels = raw.get("labels") or {}
    if not isinstance(labels, dict):
        return None
    english = labels.get("en") if isinstance(labels.get("en"), dict) else None
    if english and english.get("value"):
        return str(english["value"]).strip()
    for item in labels.values():
        if isinstance(item, dict) and item.get("value"):
            return str(item["value"]).strip()
    sitelinks = raw.get("sitelinks") if isinstance(raw.get("sitelinks"), dict) else {}
    wiki = sitelinks.get("enwiki") if isinstance(sitelinks, dict) else None
    if isinstance(wiki, dict) and wiki.get("title"):
        return str(wiki["title"]).strip()
    return None


def _description(raw: dict) -> str | None:
    descriptions = raw.get("descriptions") or {}
    if not isinstance(descriptions, dict):
        return None
    english = descriptions.get("en") if isinstance(descriptions.get("en"), dict) else None
    if english and english.get("value"):
        text = str(english["value"]).strip()
        return text[:280] if text else None
    return None


def _claim_qids(claims: dict, property_id: str) -> list[int]:
    rows = claims.get(property_id) or []
    qids: list[int] = []
    for row in rows:
        if not isinstance(row, dict):
            continue
        snak = row.get("mainsnak") or {}
        if not isinstance(snak, dict) or snak.get("snaktype") != "value":
            continue
        value = (snak.get("datavalue") or {}).get("value") if isinstance(snak.get("datavalue"), dict) else None
        if not isinstance(value, dict):
            continue
        qid = parse_qid(value.get("id"))
        if qid is None:
            numeric = value.get("numeric-id")
            qid = int(numeric) if isinstance(numeric, int) else parse_qid(numeric)
        if qid is not None:
            qids.append(qid)
    return list(dict.fromkeys(qids))


def _junk_title(title: str) -> bool:
    lowered = title.strip().lower()
    return lowered.startswith("wikimedia") or lowered.startswith("wikipedia:") or "wikimedia" in lowered


def _retry_delay(response: httpx.Response, attempt: int) -> float:
    raw = response.headers.get("Retry-After")
    if raw:
        try:
            return min(max(float(raw), 0.0), 5.0)
        except ValueError:
            pass
    return min(2.0, 0.4 * (attempt + 1))
