"""Place an extend request in one contains tree.

Level 1 is a broad domain. A topic such as parenting or dinosaurs sits at
level 2 under the domain that contains it, and the parts of the request hang
under that topic.
"""

from __future__ import annotations

import re
from dataclasses import dataclass

from app.features.knowledge_graph.identity import canonical_key_for, same_topic


@dataclass(frozen=True)
class Domain:
    title: str
    explanation: str
    cues: tuple[str, ...]


DOMAINS = (
    Domain(
        "Life sciences",
        "Covers living organisms, how they function, and how life has changed over time.",
        ("dinosaur", "biology", "organism", "ecology", "evolution", "zoology", "botany", "fossil", "genetics", "animal", "plant", "bird", "mammal", "insect", "species"),
    ),
    Domain(
        "Physical health",
        "Covers the human body, fitness, nutrition, illness, and medicine.",
        ("medicine", "fitness", "nutrition", "disease", "exercise", "anatomy", "health"),
    ),
    Domain(
        "Social sciences",
        "Covers societies, economies, politics, and how people live together.",
        ("sociology", "economics", "politics", "anthropology", "society", "culture"),
    ),
    Domain(
        "Literature",
        "Covers written works of art, including poetry, fiction, and drama.",
        ("literature", "poetry", "novel", "fiction", "drama", "shakespeare"),
    ),
    Domain(
        "Life skills",
        "Covers practical abilities for everyday life, including raising children and running a household.",
        ("parenting", "parent", "childcare", "child rearing", "raising children", "household"),
    ),
    Domain(
        "Psychology",
        "Covers the mind, behavior, cognition, and personality.",
        ("psychology", "cognition", "personality", "perception", "behavior", "behaviour", "memory"),
    ),
    Domain(
        "Mental wellbeing",
        "Covers emotions, stress, and caring for one's mental health.",
        ("wellbeing", "well-being", "anxiety", "depression", "mindfulness", "stress", "mental health"),
    ),
    Domain(
        "Mathematics",
        "Covers number, shape, pattern, and mathematical reasoning.",
        ("mathematics", "algebra", "geometry", "calculus", "statistics", "arithmetic"),
    ),
    Domain(
        "Physical sciences",
        "Covers matter, energy, space, and the non-living physical world.",
        ("physics", "chemistry", "astronomy", "geology", "climate"),
    ),
    Domain(
        "History",
        "Covers past events, eras, and how human affairs have changed.",
        ("history", "ancient", "empire", "civilization", "civilisation"),
    ),
    Domain(
        "Arts",
        "Covers making and understanding music, pictures, performance, and film.",
        ("music", "painting", "sculpture", "theatre", "theater", "cinema", "dance"),
    ),
    Domain(
        "Technology",
        "Covers tools, machines, computing, and engineered systems.",
        ("technology", "computer", "software", "internet", "engineering"),
    ),
    Domain(
        "Language",
        "Covers languages, grammar, and how meaning is expressed in words.",
        ("language", "grammar", "linguistics", "vocabulary", "syntax"),
    ),
)


def seat_branch(branch: dict, instruction: str, existing: list | None = None) -> dict:
    """Give this request one subject node and the parent it belongs under."""
    subject = instruction.strip()
    if not subject:
        return branch
    nodes = [node for node in (branch.get("nodes") or []) if isinstance(node, dict)]
    edges = [edge for edge in (branch.get("edges") or []) if isinstance(edge, dict)]
    branch["nodes"] = nodes
    branch["edges"] = edges
    catalog = [node for node in (existing or []) if isinstance(node, dict)]

    named = _named_domain(subject)
    if named is not None:
        root = _ensure(nodes, named.title, named.explanation, 1, catalog)
        _gather(nodes, edges, root)
        _rewrite_levels(nodes, edges, root, 1)
        return branch

    parent = _specific_parent(catalog, subject)
    if parent is not None and parent.get("concept_id"):
        topic_level = int(parent.get("level") or 1) + 1
        topic = _ensure(nodes, _display(subject), f"Covers the range of {_display(subject)}.", topic_level, catalog)
        _gather(nodes, edges, topic)
        _link(edges, str(parent["concept_id"]), topic)
        _rewrite_levels(nodes, edges, topic, topic_level)
        return branch

    domain = _containing_domain(subject)
    topic = _ensure(nodes, _display(subject), f"Covers the range of {_display(subject)}.", 2, catalog)
    domain_temp = _find(nodes, domain.title) if domain is not None else None
    skip = {topic}
    if domain_temp:
        skip.add(domain_temp)
    _gather(nodes, edges, topic, skip=skip)
    if domain is not None and topic not in _incoming(edges):
        holder = domain_temp or _ensure(nodes, domain.title, domain.explanation, 1, catalog)
        _link(edges, holder, topic)
    _rewrite_levels(nodes, edges, topic, 2)
    return branch


def _named_domain(instruction: str) -> Domain | None:
    for domain in DOMAINS:
        if same_topic(instruction, domain.title):
            return domain
    return None


def _containing_domain(instruction: str) -> Domain | None:
    text = instruction.lower()
    best: Domain | None = None
    best_score = 0
    for domain in DOMAINS:
        score = sum(len(cue) for cue in domain.cues if _has_cue(text, cue))
        if score > best_score:
            best = domain
            best_score = score
    return best


def _specific_parent(existing: list[dict], instruction: str) -> dict | None:
    matches = [node for node in existing if _title_inside(str(node.get("title") or ""), instruction)]
    if not matches:
        return None
    matches.sort(key=lambda node: (len(str(node.get("title") or "")), int(node.get("level") or 0)), reverse=True)
    return matches[0]


def _title_inside(title: str, instruction: str) -> bool:
    if len(title.strip()) < 4 or same_topic(title, instruction):
        return False
    text = instruction.lower()
    phrase = title.strip().lower()
    if _has_cue(text, phrase):
        return True
    if " " not in phrase and phrase.endswith("s") and len(phrase) > 4:
        return _has_cue(text, phrase[:-1])
    return False


def _has_cue(text: str, cue: str) -> bool:
    return re.search(rf"(?<![a-z0-9]){re.escape(cue.lower())}", text) is not None


def _ensure(nodes: list[dict], title: str, explanation: str, level: int, existing: list[dict]) -> str:
    found = _find(nodes, title)
    if found is None:
        found = f"seat-{canonical_key_for(title)}"
        nodes.insert(
            0,
            {
                "temp_id": found,
                "title": title,
                "summary": title,
                "explanation": explanation,
                "level": level,
                "canonical_key": canonical_key_for(title),
            },
        )
    for node in nodes:
        if str(node.get("temp_id")) != found:
            continue
        node["level"] = level
        prior = next((item for item in existing if same_topic(str(item.get("title") or ""), title)), None)
        if prior is not None and prior.get("concept_id"):
            node["concept_id"] = prior["concept_id"]
        if not str(node.get("explanation") or "").strip():
            node["explanation"] = explanation
        break
    return found


def _find(nodes: list[dict], title: str) -> str | None:
    for node in nodes:
        if same_topic(str(node.get("title") or ""), title):
            temp = node.get("temp_id")
            if temp:
                return str(temp)
    return None


def _gather(nodes: list[dict], edges: list[dict], root: str, skip: set[str] | None = None) -> None:
    held = {root, *(skip or set())}
    for node in nodes:
        temp = str(node.get("temp_id") or "")
        if not temp or temp in held or temp in _incoming(edges):
            continue
        _link(edges, root, temp)


def _incoming(edges: list[dict]) -> set[str]:
    return {str(edge.get("to")) for edge in edges if edge.get("type") == "contains" and edge.get("to")}


def _rewrite_levels(nodes: list[dict], edges: list[dict], root: str, root_level: int) -> None:
    """Keep each part deeper than the node that contains it, so a mention in an explanation does not swallow it."""
    by_temp = {str(node.get("temp_id")): node for node in nodes if node.get("temp_id")}
    children: dict[str, list[str]] = {}
    for edge in edges:
        if edge.get("type") != "contains":
            continue
        children.setdefault(str(edge.get("from")), []).append(str(edge.get("to")))
    seen = {root}
    queue = [(root, root_level)]
    while queue:
        current, level = queue.pop(0)
        node = by_temp.get(current)
        if node is not None:
            node["level"] = level
        for child in children.get(current, []):
            if child in seen:
                continue
            seen.add(child)
            queue.append((child, level + 1))


def _link(edges: list[dict], source: str, target: str) -> None:
    if not source or not target or source == target:
        return
    for edge in edges:
        if str(edge.get("type") or "") == "contains" and str(edge.get("from")) == source and str(edge.get("to")) == target:
            return
    edges.append({"from": source, "to": target, "type": "contains", "is_primary_parent": True})


def _display(instruction: str) -> str:
    text = instruction.strip()
    if any(char.isupper() for char in text):
        return text
    return text[:1].upper() + text[1:]
