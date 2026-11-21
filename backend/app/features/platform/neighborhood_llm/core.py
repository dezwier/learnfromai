"""Neighborhood LLM protocol, prompts, and shared helpers."""

from __future__ import annotations

import json
import re
from typing import Protocol
from uuid import UUID

from app.core.config import get_settings
from app.features.knowledge_graph.identity import canonical_key_for
from app.features.platform.llm_usage_pricing import usage_from_tokens

PROMPT_NEIGHBORHOOD = "neighborhood_v6"
PROMPT_SAMENESS = "sameness_v3"

BUCKETS = ("parents", "siblings", "children", "acquaintances")


class NeighborhoodLLM(Protocol):
    name: str

    def generate_neighborhood(self, topic: str, counts: dict[str, int]) -> tuple[dict, dict]: ...

    def match_topics(self, candidates: list[dict]) -> tuple[dict, dict]: ...


def _usage(model: str, input_tokens: int = 12, output_tokens: int = 24) -> dict:
    return usage_from_tokens(
        model,
        input_tokens=input_tokens,
        output_tokens=output_tokens,
        source="synthetic",
    )


def _topic(name: str, description: str) -> dict:
    return {"name": name, "description": description}


def _distribute(total: int, min_per: int) -> dict[str, int]:
    """Split a total across four buckets with at least min_per each when possible."""
    total = max(0, int(total))
    min_per = max(0, int(min_per))
    if total == 0:
        return {bucket: 0 for bucket in BUCKETS}
    reserved = min(total, min_per * len(BUCKETS))
    base = reserved // len(BUCKETS) if reserved else 0
    sizes = {bucket: base for bucket in BUCKETS}
    leftover = total - base * len(BUCKETS)
    # Prefer children, then acquaintances, siblings, parents for extras.
    order = ("children", "acquaintances", "siblings", "parents")
    index = 0
    while leftover > 0:
        sizes[order[index % len(order)]] += 1
        leftover -= 1
        index += 1
    return sizes


def build_neighborhood_prompt(topic: str, counts: dict) -> str:
    total = int(counts.get("total") or 16)
    prefer = counts.get("prefer_buckets") if isinstance(counts.get("prefer_buckets"), list) else []
    exclude_titles = [
        str(title).strip()
        for title in (counts.get("exclude_titles") or [])
        if str(title).strip()
    ]
    prefer_line = ""
    if prefer:
        prefer_line = (
            f" Prefer adding into these underfilled roles when they fit: "
            f"{', '.join(map(str, prefer))}."
        )
    exclude_line = ""
    if exclude_titles:
        exclude_line = (
            " Do not repeat these existing neighbor titles (or near-variants): "
            + ", ".join(exclude_titles)
            + "."
        )
    return (
        "Build a learning neighborhood around one topic. Return JSON only with keys "
        "focus, parents, siblings, children, acquaintances. "
        "focus is {name, description}. Each other key is an array of {name, description}. "
        f"Aim for about {total} related topics in total. "
        "You decide how many go in each role: vaguely a bit of everything, "
        "usually most as children, otherwise whatever best covers a cloud of related topics."
        f"{prefer_line}{exclude_line} "
        "Parents = broader. Siblings = peers under a shared broader class. "
        "Children = narrower. Acquaintances = related but not parent/sibling/child. "
        "Names: short Wikipedia-style titles; one node per concept "
        "(no singular/plural pairs, British/American spelling pairs, or title vs "
        "title+Documentary/Film/Series). "
        "Descriptions: one short standalone sentence; do not name the seed topic. "
        "No duplicates across buckets. Seed: "
        + json.dumps(
            {
                "topic": topic,
                "total": total,
                "exclude_titles": exclude_titles,
            }
        )
    )


def build_sameness_prompt(candidates: list[dict]) -> str:
    return (
        "Decide which existing topics are the same concept as each candidate. Return JSON "
        '{"matches": {"<key>": "<uuid-or-null>"}}. '
        "Match aggressively when wording differs but the real-world subject is the same. "
        "Always treat these as the same concept: singular↔plural (Dinosaur/Dinosaurs), "
        "common↔scientific taxon labels (Dinosaurs/Dinosauria, Ornithischia/Ornithischians, "
        "Theropoda/Theropods, Sauropoda/Sauropods), "
        "British↔American spelling (Paleontology/Palaeontology, Archaeology/Archeology), "
        "and a work title ↔ the same title plus a medium qualifier "
        "(The Last Dance / The Last Dance Documentary; also Film, Series, Album, Podcast, Show). "
        "Pick the best existing id when several are close. "
        "Return null only when they are clearly different subjects "
        "(Bass the fish vs Bass the musical range).\n"
        + json.dumps({"candidates": candidates})
    )


def _normalize_sameness(parsed: dict) -> dict:
    matches = parsed.get("matches") if isinstance(parsed, dict) else {}
    if not isinstance(matches, dict):
        matches = {}
    cleaned = {
        str(key): (str(value) if value not in (None, "", "null") else None)
        for key, value in matches.items()
    }
    return {"matches": cleaned}


def _exclude_keys(counts: dict) -> set[str]:
    raw = counts.get("exclude_titles") if isinstance(counts, dict) else None
    if not isinstance(raw, list):
        return set()
    return {canonical_key_for(str(title)) for title in raw if str(title).strip()}


def _without_excluded(rows: list[dict], exclude: set[str]) -> list[dict]:
    if not exclude:
        return rows
    return [row for row in rows if canonical_key_for(str(row.get("name") or "")) not in exclude]


def _normalize_neighborhood(raw: dict, counts: dict[str, int]) -> dict:
    focus = raw.get("focus") if isinstance(raw.get("focus"), dict) else {}
    result = {
        "focus": {
            "name": str(focus.get("name") or "Topic").strip() or "Topic",
            "description": str(focus.get("description") or "").strip() or None,
        }
    }
    exclude = _exclude_keys(counts)
    kept: dict[str, list[dict]] = {}
    for bucket in BUCKETS:
        rows = raw.get(bucket) if isinstance(raw.get(bucket), list) else []
        cleaned = []
        for row in rows:
            if not isinstance(row, dict):
                continue
            name = str(row.get("name") or "").strip()
            if not name or canonical_key_for(name) in exclude:
                continue
            cleaned.append(
                {
                    "name": name,
                    "description": str(row.get("description") or "").strip() or None,
                }
            )
        kept[bucket] = cleaned

    # Preserve the model's mix; only drop excluded titles and cap at total.
    total = int(counts.get("total") or sum(len(v) for v in kept.values()) or 16)
    used = sum(len(v) for v in kept.values())
    # Trim extras while preferring to keep children.
    trim_order = ("parents", "siblings", "acquaintances", "children")
    while used > total:
        progressed = False
        for bucket in trim_order:
            if used <= total:
                break
            if kept[bucket]:
                kept[bucket].pop()
                used -= 1
                progressed = True
        if not progressed:
            break
    result.update(kept)
    return result


def _strip_fences(text: str) -> str:
    stripped = text.strip()
    if stripped.startswith("```"):
        stripped = re.sub(r"^```(?:json)?", "", stripped).strip()
        stripped = re.sub(r"```$", "", stripped).strip()
    return stripped


def _loads_json_object(text: str) -> dict:
    """Parse a JSON object, tolerating fences or leading/trailing chatter."""
    stripped = _strip_fences(text)
    try:
        parsed = json.loads(stripped)
    except json.JSONDecodeError:
        start = stripped.find("{")
        end = stripped.rfind("}")
        if start < 0 or end <= start:
            raise
        parsed = json.loads(stripped[start : end + 1])
    if not isinstance(parsed, dict):
        raise ValueError("LLM JSON root must be an object")
    return parsed


def _parse_gemini_payload(payload: dict) -> dict:
    candidates = payload.get("candidates") or []
    if not candidates:
        prompt_feedback = payload.get("promptFeedback") or {}
        raise ValueError(f"Gemini returned no candidates ({prompt_feedback})")
    candidate = candidates[0] if isinstance(candidates[0], dict) else {}
    finish = str(candidate.get("finishReason") or "")
    if finish in {"SAFETY", "RECITATION", "BLOCKLIST", "PROHIBITED_CONTENT"}:
        raise ValueError(f"Gemini blocked the response ({finish})")
    parts = ((candidate.get("content") or {}).get("parts")) or []
    chunks = [str(part.get("text") or "") for part in parts if isinstance(part, dict)]
    text = "".join(chunks).strip()
    if not text:
        raise ValueError(f"Gemini returned empty text (finish={finish or 'unknown'})")
    try:
        return _loads_json_object(text)
    except json.JSONDecodeError as exc:
        preview = re.sub(r"\s+", " ", text)[:180]
        raise ValueError(f"Invalid JSON from Gemini: {exc.msg}; preview={preview!r}") from exc


def _parse_openai_payload(payload: dict) -> dict:
    choices = payload.get("choices") or []
    if not choices:
        raise ValueError("OpenAI returned no choices")
    choice = choices[0] if isinstance(choices[0], dict) else {}
    finish = str(choice.get("finish_reason") or "")
    if finish == "content_filter":
        raise ValueError("OpenAI blocked the response (content_filter)")
    message = choice.get("message") if isinstance(choice.get("message"), dict) else {}
    text = str(message.get("content") or "").strip()
    if not text:
        raise ValueError(f"OpenAI returned empty text (finish={finish or 'unknown'})")
    try:
        return _loads_json_object(text)
    except json.JSONDecodeError as exc:
        preview = re.sub(r"\s+", " ", text)[:180]
        raise ValueError(f"Invalid JSON from OpenAI: {exc.msg}; preview={preview!r}") from exc


def normalize_llm_provider(value: object | None) -> str | None:
    """Map UI/env aliases to gemini | openai | fake, or None if unset/invalid."""
    if value is None:
        return None
    choice = str(value).strip().lower()
    if not choice:
        return None
    if choice in {"openai", "gpt", "chatgpt"}:
        return "openai"
    if choice in {"gemini", "google"}:
        return "gemini"
    if choice == "fake":
        return "fake"
    return None


def resolve_llm_provider(preferred: object | None = None) -> str:
    """Resolve provider: explicit preference → env default → openai."""
    settings = get_settings()
    if settings.environment == "test":
        return "fake"
    for candidate in (preferred, settings.llm_provider, "openai"):
        normalized = normalize_llm_provider(candidate)
        if normalized:
            return normalized
    return "openai"




def get_neighborhood_llm(provider: str | None = None) -> NeighborhoodLLM:
    from app.features.platform.neighborhood_llm.providers import (
        FakeNeighborhoodLLM,
        GeminiNeighborhoodLLM,
        OpenAINeighborhoodLLM,
    )

    choice = resolve_llm_provider(provider)
    if choice == "fake":
        return FakeNeighborhoodLLM()
    if choice == "openai":
        return OpenAINeighborhoodLLM()
    return GeminiNeighborhoodLLM()


def parse_uuid(value: object) -> UUID | None:
    if value is None:
        return None
    try:
        return UUID(str(value))
    except (TypeError, ValueError):
        return None
