"""Related-topic cloud from Wikipedia morelike search."""

from __future__ import annotations

import time
from collections.abc import Callable
from dataclasses import dataclass

import httpx

from app.core.config import get_settings
from app.features.knowledge_graph.wikidata import parse_qid

USER_AGENT = "AdaptiveMastery/1.0 (https://github.com/dezwier/learnfromai; knowledge graph)"
_RETRY_CODES = {"ratelimited", "maxlag"}


class WikipediaError(Exception):
    """Wikipedia could not return a usable response."""


@dataclass(frozen=True)
class RelatedHit:
    title: str
    qid: int | None
    description: str | None = None


class WikipediaRelatedClient:
    """Find related English Wikipedia pages and join them to Wikidata qids."""

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
                timeout=self._settings.wikipedia_timeout_seconds,
                headers={"User-Agent": self._settings.wikipedia_user_agent or USER_AGENT},
                transport=self._transport,
                follow_redirects=True,
            )
        return self._http

    def related(self, enwiki_title: str, *, limit: int = 8) -> list[RelatedHit]:
        title = (enwiki_title or "").strip()
        if not title or limit <= 0:
            return []
        search = self._get(
            {
                "action": "query",
                "list": "search",
                "srsearch": f"morelike:{title}",
                "srnamespace": "0",
                "srlimit": str(limit),
                "srprop": "",
            }
        )
        pages = ((search.get("query") or {}).get("search")) or []
        titles = [str(row.get("title")).strip() for row in pages if isinstance(row, dict) and row.get("title")]
        titles = [name for name in titles if name and name.lower() != title.lower()][:limit]
        if not titles:
            return []
        props = self._get(
            {
                "action": "query",
                "prop": "pageprops|description",
                "ppprop": "wikibase_item",
                "titles": "|".join(titles),
                "redirects": "1",
            }
        )
        by_title = _pages_by_title(props)
        hits: list[RelatedHit] = []
        for name in titles:
            page = by_title.get(name.lower())
            if page is None:
                continue
            pageprops = page.get("pageprops") if isinstance(page.get("pageprops"), dict) else {}
            qid = parse_qid(pageprops.get("wikibase_item")) if isinstance(pageprops, dict) else None
            description = page.get("description")
            desc = str(description).strip()[:280] if description else None
            hits.append(RelatedHit(title=str(page.get("title") or name), qid=qid, description=desc))
        return hits

    def _get(self, params: dict[str, object]) -> dict:
        query = {"format": "json"}
        for key, value in params.items():
            if value is None:
                continue
            query[str(key)] = value if isinstance(value, str) else str(value)
        client = self._connection()
        last_error: Exception | None = None
        for attempt in range(4):
            try:
                response = client.get(self._settings.wikipedia_api_url, params=query)
            except httpx.HTTPError as exc:
                last_error = exc
                if attempt == 3:
                    break
                self._sleeper(min(2.0, 0.4 * (attempt + 1)))
                continue
            if response.status_code == 429 or response.status_code >= 500:
                last_error = WikipediaError(f"Wikipedia returned HTTP {response.status_code}")
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
                last_error = WikipediaError(str(error.get("info") or error.get("code")))
                if attempt == 3:
                    break
                self._sleeper(_retry_delay(response, attempt))
                continue
            if isinstance(error, dict):
                raise WikipediaError(str(error.get("info") or error.get("code") or "Wikipedia request failed"))
            if not isinstance(payload, dict):
                raise WikipediaError("Wikipedia returned an unexpected payload")
            return payload
        raise WikipediaError("Wikipedia could not be reached") from last_error


def _pages_by_title(payload: dict) -> dict[str, dict]:
    pages = ((payload.get("query") or {}).get("pages")) or {}
    redirects = ((payload.get("query") or {}).get("redirects")) or []
    normalized = ((payload.get("query") or {}).get("normalized")) or []
    alias: dict[str, str] = {}
    for row in normalized:
        if isinstance(row, dict) and row.get("from") and row.get("to"):
            alias[str(row["from"]).lower()] = str(row["to"])
    for row in redirects:
        if isinstance(row, dict) and row.get("from") and row.get("to"):
            alias[str(row["from"]).lower()] = str(row["to"])
    by_canonical: dict[str, dict] = {}
    if isinstance(pages, dict):
        for page in pages.values():
            if not isinstance(page, dict) or page.get("missing") is not None:
                continue
            title = str(page.get("title") or "").strip()
            if title:
                by_canonical[title.lower()] = page
    result: dict[str, dict] = dict(by_canonical)
    for source, target in alias.items():
        page = by_canonical.get(target.lower())
        if page is not None:
            result[source] = page
    return result


def _retry_delay(response: httpx.Response, attempt: int) -> float:
    raw = response.headers.get("Retry-After")
    if raw:
        try:
            return min(max(float(raw), 0.0), 5.0)
        except ValueError:
            pass
    return min(2.0, 0.4 * (attempt + 1))
