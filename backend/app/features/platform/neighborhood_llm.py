"""LLM contracts for neighborhood generation and topic sameness."""

from __future__ import annotations

import json
import logging
import re
from typing import Protocol
from uuid import UUID

import httpx

from app.core.config import get_settings
from app.core.errors import generation_unavailable
from app.features.knowledge_graph.identity import canonical_key_for

logger = logging.getLogger(__name__)

PROMPT_NEIGHBORHOOD = "neighborhood_v4"
PROMPT_SAMENESS = "sameness_v3"
INPUT_USD_PER_TOKEN = 0.10 / 1_000_000
OUTPUT_USD_PER_TOKEN = 0.40 / 1_000_000

BUCKETS = ("parents", "siblings", "children", "acquaintances")


class NeighborhoodLLM(Protocol):
    name: str

    def generate_neighborhood(self, topic: str, counts: dict[str, int]) -> tuple[dict, dict]: ...

    def match_topics(self, candidates: list[dict]) -> tuple[dict, dict]: ...


def _usage(model: str, input_tokens: int = 12, output_tokens: int = 24) -> dict:
    return {
        "model": model,
        "input_tokens": input_tokens,
        "output_tokens": output_tokens,
        "estimated_cost_usd": input_tokens * INPUT_USD_PER_TOKEN + output_tokens * OUTPUT_USD_PER_TOKEN,
    }


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


class FakeNeighborhoodLLM:
    name = "fake"

    def generate_neighborhood(self, topic: str, counts: dict[str, int]) -> tuple[dict, dict]:
        seed = topic.strip() or "Dinosaurs"
        key = canonical_key_for(seed)
        sizes = _distribute(int(counts.get("total") or 16), int(counts.get("min_per_bucket") or 2))
        prefer = counts.get("prefer_buckets") if isinstance(counts.get("prefer_buckets"), list) else []
        if prefer:
            # Repair: bias toward underfilled buckets.
            sizes = {bucket: 0 for bucket in BUCKETS}
            remaining = int(counts.get("total") or 0)
            order = [bucket for bucket in prefer if bucket in sizes] + list(BUCKETS)
            index = 0
            while remaining > 0 and order:
                sizes[order[index % len(order)]] += 1
                remaining -= 1
                index += 1
        if "dinosaur" in key or key in {"dinosaurs", "dinosaur"}:
            pools = {
                "parents": [
                    _topic("Reptiles", "Cold-blooded vertebrates with scales that lay amniotic eggs."),
                    _topic("Animals", "Multicellular organisms that ingest organic matter for energy."),
                    _topic("Vertebrates", "Animals with a backbone or spinal column."),
                    _topic("Archosaurs", "Ruling reptiles that include dinosaurs, birds, and crocodilians."),
                ],
                "siblings": [
                    _topic("Mammals", "Warm-blooded vertebrates that nurse young with milk."),
                    _topic("Crocodilians", "Large aquatic reptiles with elongated snouts and armored skin."),
                    _topic("Birds", "Feathered vertebrates adapted for flight and nesting."),
                    _topic("Pterosaurs", "Flying reptiles of the Mesozoic with membranous wings."),
                ],
                "children": [
                    _topic("Theropods", "Bipedal dinosaurs that include many carnivores and bird ancestors."),
                    _topic("Sauropods", "Long-necked herbivorous dinosaurs with pillar-like limbs."),
                    _topic("Ornithischians", "Bird-hipped dinosaurs that were mostly plant eaters."),
                    _topic("Ceratopsians", "Horned plant-eating dinosaurs with frilled skulls."),
                    _topic("Stegosaurs", "Plated herbivorous dinosaurs with spiked tails."),
                    _topic("Ankylosaurs", "Armored plant-eating dinosaurs with clubbed or spiked tails."),
                ],
                "acquaintances": [
                    _topic("Paleontology", "The scientific study of prehistoric life through fossils."),
                    _topic("Fossils", "Preserved remains or traces of ancient organisms in rock."),
                    _topic("Mesozoic", "The geologic era spanning Triassic, Jurassic, and Cretaceous periods."),
                    _topic("Continental drift", "The gradual movement of Earth's landmasses over geologic time."),
                    _topic("Extinction", "The end of a species or larger group of organisms."),
                    _topic("Geology", "The study of Earth's physical structure and history."),
                ],
            }
            payload = {
                "focus": _topic("Dinosaurs", "Extinct Mesozoic reptiles known from fossils worldwide."),
                **{bucket: pools[bucket][: sizes[bucket]] for bucket in BUCKETS},
            }
        else:
            title = seed[:1].upper() + seed[1:] if seed else "Topic"
            payload = {
                "focus": _topic(title, f"A standalone subject covering {title.lower()}."),
                "parents": [
                    _topic(f"Field of {title}" if i == 1 else f"Domain of {title} {i}", f"A broader field around {title.lower()}.")
                    for i in range(1, sizes["parents"] + 1)
                ],
                "siblings": [
                    _topic(f"Sibling of {title} {index}", f"A peer subject beside {title.lower()}.")
                    for index in range(1, sizes["siblings"] + 1)
                ],
                "children": [
                    _topic(f"Part of {title} {index}", f"A narrower subject under {title.lower()}.")
                    for index in range(1, sizes["children"] + 1)
                ],
                "acquaintances": [
                    _topic(f"Related to {title} {index}", f"A neighboring subject near {title.lower()}.")
                    for index in range(1, sizes["acquaintances"] + 1)
                ],
            }
        return payload, _usage("fake")

    def match_topics(self, candidates: list[dict]) -> tuple[dict, dict]:
        from app.features.knowledge_graph.identity import same_topic

        matches: dict[str, str | None] = {}
        for item in candidates:
            key = str(item.get("key") or "")
            existing = item.get("existing") or []
            name = str(item.get("name") or "")
            chosen = None
            for row in existing:
                if not isinstance(row, dict):
                    continue
                other = str(row.get("name") or "")
                # Exact key or morphological / media-suffix near-duplicate for tests.
                if canonical_key_for(other) == canonical_key_for(name) or same_topic(other, name):
                    chosen = str(row.get("id"))
                    break
            matches[key] = chosen
        return {"matches": matches}, _usage("fake")


class GeminiNeighborhoodLLM:
    name = "gemini"

    def __init__(self) -> None:
        settings = get_settings()
        self.api_key = settings.google_gemini_api_key
        self.model = settings.gemini_model
        self.temperature = settings.gemini_temperature

    def generate_neighborhood(self, topic: str, counts: dict[str, int]) -> tuple[dict, dict]:
        total = int(counts.get("total") or 16)
        min_per = int(counts.get("min_per_bucket") or 2)
        prefer = counts.get("prefer_buckets") if isinstance(counts.get("prefer_buckets"), list) else []
        prefer_line = ""
        if prefer:
            prefer_line = (
                f" Prefer putting new topics into these underfilled roles when they fit: {', '.join(map(str, prefer))}."
            )
        prompt = (
            "Build a learning neighborhood for one topic. Return JSON only with keys "
            "focus, parents, siblings, children, acquaintances. "
            "focus is {name, description}. Each other key is an array of {name, description}. "
            f"Return about {total} related topics in total across the four arrays "
            f"(sum of array lengths ≈ {total}). "
            f"Include at least {min_per} item(s) in each of parents, siblings, children, and acquaintances "
            "when the total allows; otherwise at least one in each role you can justify. "
            "You choose how many go in each bucket — a bit of everything, weighted toward what fits the topic "
            "(e.g. more children for a broad subject, more acquaintances for a cross-cutting one)."
            f"{prefer_line} "
            "Names are the single best canonical standalone title for each concept (Wikipedia-style page title). "
            "Prefer the common group name over near-variants: one node for Dinosaur/Dinosaurs/Dinosauria, "
            "one for Ornithischia/Ornithischians, one for Theropoda/Theropods (and other -oda/-ods pairs), "
            "one for a work and the same title with a medium qualifier "
            "(The Last Dance, not also The Last Dance Documentary). "
            "Never emit singular and plural, vernacular and scientific taxon labels, British/American spelling "
            "pairs (Paleontology/Palaeontology, Archaeology/Archeology), or title-vs-title+Documentary/"
            "Film/Series/Album/Podcast/Show as separate topics in this response. Prefer the simpler/"
            "American spelling when both exist. "
            "Descriptions are one short sentence that stands alone and must not refer to the seed topic by name "
            "or as 'this topic'. Keep names short. "
            "Parents are broader subjects. Siblings are peer subjects under a shared broader class. "
            "Children are narrower subjects. Acquaintances are clearly related but not parent/sibling/child. "
            "No duplicates across buckets. Seed topic: "
            + json.dumps({"topic": topic, "total": total, "min_per_bucket": min_per})
        )
        parsed, usage = self._json(prompt, PROMPT_NEIGHBORHOOD)
        return _normalize_neighborhood(parsed, counts), usage

    def match_topics(self, candidates: list[dict]) -> tuple[dict, dict]:
        prompt = (
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
        parsed, usage = self._json(prompt, PROMPT_SAMENESS)
        matches = parsed.get("matches") if isinstance(parsed, dict) else {}
        if not isinstance(matches, dict):
            matches = {}
        cleaned = {str(key): (str(value) if value not in (None, "", "null") else None) for key, value in matches.items()}
        return {"matches": cleaned}, usage

    def _json(self, prompt: str, prompt_version: str) -> tuple[dict, dict]:
        if not self.api_key:
            raise generation_unavailable("GOOGLE_GEMINI_API_KEY is not configured", terminal=True)
        url = f"https://generativelanguage.googleapis.com/v1beta/models/{self.model}:generateContent"
        body = {
            "contents": [{"role": "user", "parts": [{"text": prompt}]}],
            "generationConfig": {
                "temperature": self.temperature,
                "responseMimeType": "application/json",
                "maxOutputTokens": 8192,
            },
        }
        logging.getLogger("httpx").setLevel(logging.WARNING)
        logging.getLogger("httpcore").setLevel(logging.WARNING)
        last_error: Exception | None = None
        heartbeat = getattr(self, "heartbeat", None)
        for attempt in range(1, 4):
            if callable(heartbeat):
                heartbeat()
            try:
                with httpx.Client(timeout=90) as client:
                    response = client.post(url, json=body, headers={"x-goog-api-key": self.api_key})
                if response.status_code == 402:
                    raise generation_unavailable("The model account has no credits left", terminal=True)
                response.raise_for_status()
                payload = response.json()
                parsed = _parse_gemini_payload(payload)
                parsed.setdefault("schema_version", 1)
                parsed.setdefault("prompt_version", prompt_version)
                meta = payload.get("usageMetadata") or {}
                usage = _usage(
                    self.model,
                    int(meta.get("promptTokenCount") or 0),
                    int(meta.get("candidatesTokenCount") or 0),
                )
                return parsed, usage
            except (httpx.HTTPError, KeyError, json.JSONDecodeError, IndexError, ValueError) as exc:
                last_error = exc
                body["generationConfig"]["maxOutputTokens"] = min(16384, 8192 * (2 ** (attempt - 1)))
                logger.info(
                    "gemini neighborhood retry %s: %s (%s)",
                    attempt,
                    type(exc).__name__,
                    str(exc)[:160],
                )
        raise generation_unavailable("Gemini did not return valid JSON") from last_error


def get_neighborhood_llm() -> NeighborhoodLLM:
    settings = get_settings()
    if settings.environment == "test" or settings.llm_provider == "fake":
        return FakeNeighborhoodLLM()
    return GeminiNeighborhoodLLM()


def _normalize_neighborhood(raw: dict, counts: dict[str, int]) -> dict:
    focus = raw.get("focus") if isinstance(raw.get("focus"), dict) else {}
    result = {
        "focus": {
            "name": str(focus.get("name") or "Topic").strip() or "Topic",
            "description": str(focus.get("description") or "").strip() or None,
        }
    }
    cleaned_buckets: dict[str, list[dict]] = {}
    for bucket in BUCKETS:
        rows = raw.get(bucket) if isinstance(raw.get(bucket), list) else []
        cleaned = []
        for row in rows:
            if not isinstance(row, dict):
                continue
            name = str(row.get("name") or "").strip()
            if not name:
                continue
            cleaned.append({"name": name, "description": str(row.get("description") or "").strip() or None})
        cleaned_buckets[bucket] = cleaned

    total = int(counts.get("total") or sum(len(v) for v in cleaned_buckets.values()) or 16)
    min_per = int(counts.get("min_per_bucket") or 0)
    # Keep a floor per bucket, then round-robin the rest up to total.
    kept: dict[str, list[dict]] = {bucket: [] for bucket in BUCKETS}
    for bucket in BUCKETS:
        floor = min(min_per, len(cleaned_buckets[bucket]))
        kept[bucket].extend(cleaned_buckets[bucket][:floor])
        cleaned_buckets[bucket] = cleaned_buckets[bucket][floor:]
    used = sum(len(v) for v in kept.values())
    while used < total:
        progressed = False
        for bucket in BUCKETS:
            if used >= total:
                break
            if cleaned_buckets[bucket]:
                kept[bucket].append(cleaned_buckets[bucket].pop(0))
                used += 1
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
        raise ValueError("Gemini JSON root must be an object")
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


def parse_uuid(value: object) -> UUID | None:
    if value is None:
        return None
    try:
        return UUID(str(value))
    except (TypeError, ValueError):
        return None
