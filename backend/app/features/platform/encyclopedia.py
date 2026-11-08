"""Build a topic graph from the encyclopedia article for a request."""

from __future__ import annotations

import re
from dataclasses import dataclass

import httpx

from app.core.errors import AppError, generation_unavailable
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
_MAIN = re.compile(r"\{\{\s*[Mm]ain\s*\|([^}]+)\}\}")
_GENERIC = {
    "anatomy",
    "behavior",
    "behaviour",
    "classification",
    "communication",
    "definition",
    "description",
    "evolution",
    "evolutionary",
    "extinction",
    "etymology",
    "feathers",
    "history",
    "origins",
    "overview",
    "paleobiology",
    "physiology",
    "reproduction",
    "research",
    "size",
    "skeleton",
    "study",
}
_MAX_FETCHES = 8
_MAX_LEVEL = 5


@dataclass(frozen=True)
class Article:
    title: str
    extract: str
    mains: dict[str, str]


def article_graph(context: dict, *, fetch=None) -> dict:
    """Nodes and contains-edges for the article that matches this request."""
    instruction = str(context.get("instruction") or "").strip()
    parent_title = str(context.get("parent_title") or "").strip()
    query = instruction or parent_title
    if not query:
        raise generation_unavailable("The request has no topic")
    loader = fetch or fetch_article
    page = _as_article(loader(query))
    subject = _scope_phrase(query, page.title)
    root_title = subject if same_topic(subject, page.title) else page.title
    limit = int(context.get("max_new_concepts") or 80)
    branch = graph_from_article(
        root_title,
        page.extract,
        existing=context.get("existing") or [],
        limit=limit,
        subject=subject,
    )
    _deepen(branch, page, subject, loader, limit)
    for node in branch["nodes"]:
        node.pop("_heading", None)
    return branch


def fetch_article(query: str) -> Article:
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
            pages = (article.json().get("query") or {}).get("pages") or {}
            page = next(iter(pages.values()), {})
            if page.get("missing") is not None or not page.get("extract"):
                raise generation_unavailable("No encyclopedia article matched this request")
            resolved = str(page.get("title") or title)
            extract = str(page["extract"])
            mains: dict[str, str] = {}
            try:
                wikitext = client.get(
                    _API,
                    params={"action": "parse", "page": resolved, "prop": "wikitext", "redirects": 1, "format": "json"},
                )
                wikitext.raise_for_status()
                raw = ((wikitext.json().get("parse") or {}).get("wikitext") or {}).get("*") or ""
                mains = _mains(str(raw))
            except httpx.HTTPError:
                mains = {}
            return Article(resolved, extract, mains)
    except AppError:
        raise
    except httpx.HTTPError as exc:
        raise generation_unavailable("The encyclopedia could not be reached") from exc


def graph_from_article(
    title: str,
    extract: str,
    *,
    existing: list,
    limit: int,
    subject: str | None = None,
    id_prefix: str = "",
) -> dict:
    catalog = _catalog(existing)
    scope = subject or title
    lead, sections = _split(extract)
    nodes: list[dict] = []
    edges: list[dict] = []
    root_id = f"{id_prefix}root"
    root = _node(root_id, title, lead, 0, catalog, heading=title)
    nodes.append(root)
    stack: list[tuple[int, str]] = [(0, root_id)]
    truncated = False
    for index, (level, heading, body) in enumerate(sections):
        if len(nodes) >= limit:
            truncated = True
            break
        while stack and stack[-1][0] >= level:
            stack.pop()
        parent = stack[-1][1] if stack else root_id
        temp = f"{id_prefix}s{index}"
        label = scoped_title(heading, scope)
        nodes.append(_node(temp, label, body, level, catalog, heading=heading))
        edges.append({"from": parent, "to": temp, "type": "contains", "is_primary_parent": True})
        stack.append((level, temp))
    return {"nodes": nodes, "edges": edges, "truncated": truncated}


def scoped_title(heading: str, subject: str) -> str:
    """A short title that still says which subject the section is about."""
    cleaned = _clean_heading(heading)
    phrase = _of_phrase(subject)
    if not cleaned:
        return phrase[:1].upper() + phrase[1:] if phrase else "Topic"
    if not phrase or _mentions(cleaned, phrase) or same_topic(cleaned, subject):
        return cleaned
    if re.search(r"\bof\b", cleaned, re.IGNORECASE):
        return f"{cleaned} ({phrase})"
    return f"{cleaned} of {phrase}"


def _as_article(loaded: object) -> Article:
    if isinstance(loaded, Article):
        return loaded
    if isinstance(loaded, tuple) and len(loaded) == 2:
        return Article(str(loaded[0]), str(loaded[1]), {})
    raise generation_unavailable("No encyclopedia article matched this request")


def _scope_phrase(query: str, article_title: str) -> str:
    text = query.strip() if query and same_topic(query, article_title) else article_title.strip()
    if not text:
        return article_title
    return text[:1].upper() + text[1:]


def _deepen(branch: dict, root: Article, subject: str, loader, limit: int) -> None:
    seen = {root.title.lower()}
    queue: list[tuple[str, str, int, int]] = []
    fetches = 0

    def enqueue(nodes: list[dict], mains: dict[str, str], depth_left: int) -> None:
        for node in nodes:
            level = int(node.get("level") or 0)
            if level == 0 or depth_left <= 0 or level >= _MAX_LEVEL:
                continue
            heading = str(node.get("_heading") or "")
            main = _lookup_main(mains, heading)
            if main:
                queue.append((str(node["temp_id"]), main, level, depth_left))
            elif level >= 2 and _worth_opening(heading):
                queue.append((str(node["temp_id"]), heading, level, depth_left))

    enqueue(branch["nodes"], root.mains, 3)
    while queue and len(branch["nodes"]) < limit and fetches < _MAX_FETCHES:
        parent_temp, article, parent_level, depth_left = queue.pop(0)
        if article.lower() in seen or parent_level >= _MAX_LEVEL:
            continue
        seen.add(article.lower())
        fetches += 1
        try:
            page = _as_article(loader(article))
        except AppError:
            continue
        if not _about_subject(page, subject):
            continue
        room = min(8, limit - len(branch["nodes"]))
        if room <= 0:
            break
        added = _graft(branch, page, parent_temp, parent_level, subject, f"d{fetches}", room)
        if depth_left > 1 and added:
            enqueue(added, page.mains, depth_left - 1)


def _graft(
    branch: dict,
    page: Article,
    parent_temp: str,
    parent_level: int,
    subject: str,
    prefix: str,
    room: int,
) -> list[dict]:
    built = graph_from_article(page.title, page.extract, existing=[], limit=room + 1, subject=subject, id_prefix=prefix)
    if len(built["nodes"]) <= 1:
        return []
    id_map = {built["nodes"][0]["temp_id"]: parent_temp}
    added: list[dict] = []
    for node in built["nodes"][1:]:
        node["level"] = parent_level + int(node["level"])
        if node["level"] > _MAX_LEVEL:
            continue
        duplicate = next((other for other in branch["nodes"] if same_topic(other["title"], node["title"])), None)
        if duplicate is not None:
            id_map[node["temp_id"]] = duplicate["temp_id"]
            continue
        branch["nodes"].append(node)
        added.append(node)
        id_map[node["temp_id"]] = node["temp_id"]
    for edge in built["edges"]:
        source = id_map.get(edge["from"])
        target = id_map.get(edge["to"])
        if not source or not target or source == target:
            continue
        branch["edges"].append({"from": source, "to": target, "type": "contains", "is_primary_parent": True})
    if built["truncated"]:
        branch["truncated"] = True
    return added


def _mains(wikitext: str) -> dict[str, str]:
    mains: dict[str, str] = {}
    current = ""
    for line in wikitext.splitlines():
        heading = _HEADING.match(line.strip())
        if heading:
            current = _clean_heading(heading.group(2))
            continue
        if not current or current.lower() in mains:
            continue
        match = _MAIN.search(line)
        if not match:
            continue
        target = match.group(1).split("|", 1)[0].strip().strip("[]")
        if target and "disambiguation" not in target.lower():
            mains[current.lower()] = target
    return mains


def _lookup_main(mains: dict[str, str], heading: str) -> str:
    return mains.get(_clean_heading(heading).lower(), "")


def _clean_heading(heading: str) -> str:
    cleaned = heading.replace("†", "").strip().strip("'")
    for prefix in ("Order ", "Suborder ", "Infraorder ", "Clade ", "Superfamily ", "Family "):
        if cleaned.startswith(prefix):
            cleaned = cleaned[len(prefix) :].strip()
    return cleaned


def _of_phrase(subject: str) -> str:
    text = subject.strip()
    if " " in text:
        return text
    return text[:1].lower() + text[1:] if text else ""


def _mentions(heading: str, subject: str) -> bool:
    words = [word for word in re.split(r"[^a-z0-9]+", subject.lower()) if len(word) >= 4]
    if not words:
        return False
    stem = words[0][:-1] if words[0].endswith("s") else words[0]
    if len(stem) < 4:
        return False
    return re.search(rf"(?<![a-z0-9]){re.escape(stem)}", heading.lower()) is not None


def _about_subject(page: Article, subject: str) -> bool:
    if _mentions(page.title, subject) or same_topic(page.title, subject):
        return True
    return _mentions(page.extract[:800], subject)


def _worth_opening(heading: str) -> bool:
    cleaned = _clean_heading(heading)
    words = [word.strip(".,") for word in cleaned.split() if word.strip(".,")]
    if not words or len(words) > 3:
        return False
    folded = {word.lower() for word in words}
    if folded & _GENERIC:
        return False
    return cleaned[:1].isupper()


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


def _node(temp_id: str, title: str, body: str, level: int, catalog: list[dict], *, heading: str) -> dict:
    explanation = _range(body, title)
    summary = _sentence(explanation, 160)
    node = {
        "temp_id": temp_id,
        "title": title,
        "summary": summary or title,
        "explanation": explanation,
        "level": level,
        "canonical_key": canonical_key_for(title),
        "_heading": heading,
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
