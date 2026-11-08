"""Build a topic graph from the encyclopedia article for a request."""

from __future__ import annotations

import re

import httpx

from app.core.errors import generation_unavailable
from app.features.knowledge_graph.identity import (
    canonical_key_for,
    is_placeholder_title,
    same_topic,
)

USER_AGENT = "AdaptiveMastery/1.0 (https://github.com/dezwier/learnfromai; knowledge graph)"
_API = "https://en.wikipedia.org/w/api.php"
_SKIPPED = {
    "see also",
    "notes",
    "note",
    "references",
    "reference",
    "bibliography",
    "further reading",
    "external links",
    "citations",
    "sources",
    "footnotes",
    "gallery",
}
_HEADING = re.compile(r"^(={2,6})\s*(.+?)\s*\1\s*$", re.MULTILINE)


def article_graph(context: dict, *, fetch=None) -> dict:
    """Nodes and contains-edges for the article that matches this request."""
    instruction = str(context.get("instruction") or "").strip()
    parent_title = str(context.get("parent_title") or "").strip()
    query = instruction or parent_title
    if not query:
        raise generation_unavailable("The request has no topic")
    loader = fetch or fetch_article
    title, extract = loader(query)
    return graph_from_article(
        title,
        extract,
        existing=context.get("existing") or [],
        limit=int(context.get("max_new_concepts") or 80),
    )


def fetch_article(query: str) -> tuple[str, str]:
    try:
        with httpx.Client(timeout=30, headers={"User-Agent": USER_AGENT}, follow_redirects=True) as client:
            search = client.get(
                _API,
                params={
                    "action": "query",
                    "list": "search",
                    "srsearch": query,
                    "srlimit": 5,
                    "format": "json",
                },
            )
            search.raise_for_status()
            payload = search.json()
            title = _search_title(payload, query)
            article = client.get(
                _API,
                params={
                    "action": "query",
                    "titles": title,
                    "prop": "extracts",
                    "explaintext": 1,
                    "exsectionformat": "wiki",
                    "redirects": 1,
                    "format": "json",
                },
            )
            article.raise_for_status()
    except httpx.HTTPError as exc:
        raise generation_unavailable("The encyclopedia could not be reached") from exc
    pages = (article.json().get("query") or {}).get("pages") or {}
    page = next(iter(pages.values()), {})
    if page.get("missing") is not None or not page.get("extract"):
        raise generation_unavailable("No encyclopedia article matched this request")
    resolved = str(page.get("title") or title)
    return resolved, str(page["extract"])


def graph_from_article(title: str, extract: str, *, existing: list, limit: int) -> dict:
    catalog = _catalog(existing)
    lead, sections = _split(extract)
    nodes: list[dict] = []
    edges: list[dict] = []
    root = _node("root", title, lead, 0, catalog)
    nodes.append(root)
    stack: list[tuple[int, str]] = [(0, "root")]
    truncated = False
    for index, (level, heading, body) in enumerate(sections):
        if len(nodes) >= limit:
            truncated = True
            break
        while stack and stack[-1][0] >= level:
            stack.pop()
        parent = stack[-1][1] if stack else "root"
        temp = f"s{index}"
        nodes.append(_node(temp, heading, body, level, catalog))
        edges.append({"from": parent, "to": temp, "type": "contains", "is_primary_parent": True})
        stack.append((level, temp))
    return {"nodes": nodes, "edges": edges, "truncated": truncated}


def _search_title(payload: dict, query: str) -> str:
    results = (payload.get("query") or {}).get("search") or []
    for item in results:
        title = str(item.get("title") or "")
        if title and "disambiguation" not in title.lower():
            return title
    suggestion = ((payload.get("query") or {}).get("searchinfo") or {}).get("suggestion")
    if suggestion:
        return str(suggestion)
    raise generation_unavailable("No encyclopedia article matched this request")


def _split(extract: str) -> tuple[str, list[tuple[int, str, str]]]:
    matches = list(_HEADING.finditer(extract))
    if not matches:
        return extract, []
    lead = extract[: matches[0].start()]
    sections: list[tuple[int, str, str]] = []
    skipping: int | None = None
    for index, match in enumerate(matches):
        level = len(match.group(1)) - 1
        heading = match.group(2).strip()
        end = matches[index + 1].start() if index + 1 < len(matches) else len(extract)
        body = extract[match.end() : end]
        if skipping is not None:
            if level > skipping:
                continue
            skipping = None
        if _skip_heading(heading):
            skipping = level
            continue
        sections.append((level, heading, body))
    return lead, sections


def _skip_heading(heading: str) -> bool:
    folded = heading.strip().lower()
    return not folded or folded in _SKIPPED or is_placeholder_title(heading)


def _node(temp_id: str, title: str, body: str, level: int, catalog: list[dict]) -> dict:
    explanation = _range(body, title)
    summary = _sentence(explanation, 160)
    node = {
        "temp_id": temp_id,
        "title": title,
        "summary": summary or title,
        "explanation": explanation,
        "level": level,
        "canonical_key": canonical_key_for(title),
    }
    match = _existing(catalog, title)
    if match is not None and match.get("concept_id"):
        node["concept_id"] = match["concept_id"]
    return node


def _existing(catalog: list[dict], title: str) -> dict | None:
    for node in catalog:
        if not isinstance(node, dict):
            continue
        other = str(node.get("title") or "")
        key = str(node.get("canonical_key") or "")
        if same_topic(other, title) or key == canonical_key_for(title):
            return node
    return None


def _catalog(existing: list) -> list[dict]:
    return [node for node in existing if isinstance(node, dict)]


def _range(body: str, title: str) -> str:
    cleaned = _clean(body)
    if not cleaned:
        return f"Covers the range of {title}."
    return _sentences(cleaned, 700)


def _sentence(text: str, limit: int) -> str:
    cleaned = _clean(text)
    end = _stop(cleaned)
    sentence = cleaned if end == len(cleaned) else cleaned[: end + 1]
    if len(sentence) <= limit:
        return sentence.strip()
    return sentence[: limit - 1].rstrip() + "."


def _sentences(text: str, limit: int) -> str:
    if len(text) <= limit:
        return text
    window = text[:limit]
    stop = max(window.rfind(". "), window.rfind("? "), window.rfind("! "))
    if stop >= 80:
        return window[: stop + 1].strip()
    return window.rstrip() + "."


def _stop(text: str) -> int:
    for mark in (". ", "? ", "! "):
        found = text.find(mark)
        if found != -1:
            return found
    if text.endswith((".", "?", "!")):
        return len(text) - 1
    return len(text)


def _clean(text: str) -> str:
    without_notes = re.sub(r"\[(?:\d+|note \d+)\]", "", text)
    return re.sub(r"\s+", " ", without_notes).strip()
