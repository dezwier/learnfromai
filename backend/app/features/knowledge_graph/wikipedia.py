"""Read category structure from the MediaWiki Action API."""

from __future__ import annotations

import re
import time
from collections.abc import Callable, Iterator
from dataclasses import dataclass

import httpx

from app.core.config import get_settings

USER_AGENT = "AdaptiveMastery/1.0 (https://github.com/dezwier/learnfromai; knowledge graph)"
_RETRY_CODES = {"ratelimited", "maxlag"}
_TITLE_BATCH = 20


class WikiError(Exception):
    """Wikipedia could not return a usable response."""


@dataclass(frozen=True)
class WikiPage:
    page_id: int
    title: str
    description: str | None
    hidden: bool
    namespace: int


class WikipediaClient:
    """HTTP client for api.php. `get` takes MediaWiki parameters and returns JSON."""

    def __init__(self, *, transport: httpx.BaseTransport | None = None, sleeper: Callable[[float], None] | None = None) -> None:
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

    def get(self, params: dict[str, object]) -> dict:
        query = {"format": "json", "formatversion": "2", "maxlag": "5"}
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
                last_error = WikiError(f"Wikipedia returned HTTP {response.status_code}")
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
                last_error = WikiError(str(error.get("info") or error.get("code")))
                if attempt == 3:
                    break
                self._sleeper(_retry_delay(response, attempt))
                continue
            if isinstance(error, dict):
                raise WikiError(str(error.get("info") or error.get("code") or "Wikipedia request failed"))
            if not isinstance(payload, dict):
                raise WikiError("Wikipedia returned an unexpected payload")
            return payload
        raise WikiError("Wikipedia could not be reached") from last_error


def display_title(title: str) -> str:
    text = title.strip()
    if text.lower().startswith("category:"):
        text = text.split(":", 1)[1].strip()
    return text


def lookup_category(api: WikipediaClient, name: str) -> WikiPage | None:
    """The category page named exactly `name`, after redirects. Hidden pages are skipped."""
    payload = api.get(
        {
            "action": "query",
            "titles": f"Category:{name}",
            "redirects": "1",
            "prop": "info|pageprops|extracts",
            "ppprop": "hiddencat",
            "exintro": "1",
            "explaintext": "1",
        }
    )
    for page in _parsed_pages(payload):
        if page.namespace == 14 and not page.hidden:
            return page
    return None


def page_by_id(api: WikipediaClient, page_id: int) -> WikiPage | None:
    pages = pages_by_ids(api, [page_id])
    return pages[0] if pages else None


def pages_by_ids(api: WikipediaClient, page_ids: list[int]) -> list[WikiPage]:
    found: list[WikiPage] = []
    unique = list(dict.fromkeys(page_ids))
    for start in range(0, len(unique), _TITLE_BATCH):
        chunk = unique[start : start + _TITLE_BATCH]
        payload = api.get(
            {
                "action": "query",
                "pageids": "|".join(str(page_id) for page_id in chunk),
                "redirects": "1",
                "prop": "info|pageprops|extracts",
                "ppprop": "hiddencat",
                "exintro": "1",
                "explaintext": "1",
            }
        )
        found.extend(_parsed_pages(payload))
    return found


def search_page_ids(api: WikipediaClient, name: str, *, namespace: int, limit: int) -> list[int]:
    payload = api.get(
        {
            "action": "query",
            "list": "search",
            "srsearch": name,
            "srnamespace": namespace,
            "srlimit": limit,
        }
    )
    hits = (payload.get("query") or {}).get("search") or []
    ids: list[int] = []
    for hit in hits:
        title = str(hit.get("title") or "")
        if "disambiguation" in title.lower() or hit.get("pageid") is None:
            continue
        ids.append(int(hit["pageid"]))
    return ids


def categories_of_page(api: WikipediaClient, page_id: int) -> list[WikiPage]:
    """Visible categories of an article or category page."""
    titles: list[str] = []
    for payload in _follow(
        api,
        {
            "action": "query",
            "prop": "categories",
            "pageids": page_id,
            "clshow": "!hidden",
            "cllimit": "max",
        },
    ):
        for page in _pages(payload):
            for category in page.get("categories") or []:
                title = category.get("title")
                if title:
                    titles.append(str(title))
    return [page for page in _resolve_titles(api, titles) if page.namespace == 14 and not page.hidden]


def parent_pages(api: WikipediaClient, page_id: int) -> list[WikiPage]:
    """Every non-hidden parent category. Raises WikiError when the page is missing or the API fails."""
    titles: list[str] = []
    saw_page = False
    for payload in _follow(
        api,
        {
            "action": "query",
            "prop": "categories",
            "pageids": page_id,
            "clshow": "!hidden",
            "cllimit": "max",
        },
    ):
        for page in _pages(payload):
            saw_page = True
            if page.get("missing") or page.get("invalid"):
                raise WikiError("Wikipedia category is missing")
            for category in page.get("categories") or []:
                title = category.get("title")
                if title:
                    titles.append(str(title))
    if not saw_page:
        raise WikiError("Wikipedia category is missing")
    return [page for page in _resolve_titles(api, titles) if page.namespace == 14 and not page.hidden]


def child_pages(api: WikipediaClient, page_id: int) -> list[WikiPage]:
    """Every non-hidden subcategory. Pagination is finished before the list is returned."""
    members: list[dict] = []
    for payload in _follow(
        api,
        {
            "action": "query",
            "list": "categorymembers",
            "cmpageid": page_id,
            "cmtype": "subcat",
            "cmlimit": "max",
        },
    ):
        members.extend((payload.get("query") or {}).get("categorymembers") or [])
    ids = [int(member["pageid"]) for member in members if member.get("pageid") is not None]
    return [page for page in pages_by_ids(api, ids) if page.namespace == 14 and not page.hidden]


def _resolve_titles(api: WikipediaClient, titles: list[str]) -> list[WikiPage]:
    found: list[WikiPage] = []
    batch: list[str] = []

    def flush(group: list[str]) -> None:
        if not group:
            return
        payload = api.get(
            {
                "action": "query",
                "titles": "|".join(group),
                "redirects": "1",
                "prop": "info|pageprops|extracts",
                "ppprop": "hiddencat",
                "exintro": "1",
                "explaintext": "1",
            }
        )
        found.extend(_parsed_pages(payload))

    for title in dict.fromkeys(titles):
        if "|" in title or len(batch) >= _TITLE_BATCH:
            flush(batch)
            batch = []
        if "|" in title:
            flush([title])
        else:
            batch.append(title)
    flush(batch)
    return found


def _follow(api: WikipediaClient, params: dict[str, object]) -> Iterator[dict]:
    current = dict(params)
    seen: set[tuple[tuple[str, str], ...]] = set()
    while True:
        payload = api.get(current)
        yield payload
        token = payload.get("continue")
        if not isinstance(token, dict) or not token:
            return
        marker = tuple(sorted((str(key), str(value)) for key, value in token.items()))
        if marker in seen:
            raise WikiError("Wikipedia repeated a continuation token")
        seen.add(marker)
        current = {**params, **{str(key): str(value) for key, value in token.items()}}


def _pages(payload: dict) -> list[dict]:
    pages = (payload.get("query") or {}).get("pages") or []
    if isinstance(pages, dict):
        return [page for page in pages.values() if isinstance(page, dict)]
    return [page for page in pages if isinstance(page, dict)]


def _parsed_pages(payload: dict) -> list[WikiPage]:
    parsed: list[WikiPage] = []
    for page in _pages(payload):
        item = _parse_page(page)
        if item is not None:
            parsed.append(item)
    return parsed


def _parse_page(page: dict) -> WikiPage | None:
    if page.get("missing") or page.get("invalid") or page.get("pageid") is None:
        return None
    title = display_title(str(page.get("title") or ""))
    if not title:
        return None
    props = page.get("pageprops") or {}
    extract = page.get("extract")
    return WikiPage(
        page_id=int(page["pageid"]),
        title=title,
        description=_description(extract if isinstance(extract, str) else None),
        hidden=isinstance(props, dict) and "hiddencat" in props,
        namespace=int(page.get("ns") or 0),
    )


def _description(extract: str | None) -> str | None:
    if not extract:
        return None
    text = re.sub(r"\s+", " ", extract).strip()
    if not text:
        return None
    stop = text.find(". ")
    sentence = text if stop == -1 else text[: stop + 1]
    return sentence[:280]


def _retry_delay(response: httpx.Response, attempt: int) -> float:
    raw = response.headers.get("Retry-After")
    if raw:
        try:
            return min(max(float(raw), 0.0), 5.0)
        except ValueError:
            pass
    return min(2.0, 0.4 * (attempt + 1))
