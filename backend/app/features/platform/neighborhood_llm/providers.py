"""Fake / Gemini / OpenAI neighborhood LLM providers."""

from __future__ import annotations

import logging

import httpx

from app.core.config import get_settings
from app.core.errors import generation_unavailable
from app.features.knowledge_graph.identity import canonical_key_for
from app.features.platform.llm_usage_pricing import (
    reserve_usd_for_call,
    usage_from_gemini_metadata,
    usage_from_openai_usage,
)
from app.features.platform.neighborhood_llm.core import (
    BUCKETS,
    PROMPT_NEIGHBORHOOD,
    PROMPT_SAMENESS,
    _distribute,
    _exclude_keys,
    _normalize_neighborhood,
    _normalize_sameness,
    _parse_gemini_payload,
    _parse_openai_payload,
    _topic,
    _usage,
    _without_excluded,
    build_neighborhood_prompt,
    build_sameness_prompt,
)

logger = logging.getLogger(__name__)

class FakeNeighborhoodLLM:
    name = "fake"

    def generate_neighborhood(self, topic: str, counts: dict[str, int]) -> tuple[dict, dict]:
        seed = topic.strip() or "Dinosaurs"
        key = canonical_key_for(seed)
        exclude = _exclude_keys(counts)
        sizes = _distribute(int(counts.get("total") or 16), int(counts.get("min_per_bucket") or 2))
        prefer = counts.get("prefer_buckets") if isinstance(counts.get("prefer_buckets"), list) else []
        if prefer:
            # Fill: bias toward underfilled buckets.
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
                **{
                    bucket: _without_excluded(pools[bucket], exclude)[: sizes[bucket]]
                    for bucket in BUCKETS
                },
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
            for bucket in BUCKETS:
                payload[bucket] = _without_excluded(payload[bucket], exclude)[: sizes[bucket]]
        return _normalize_neighborhood(payload, counts), _usage("fake")

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
        self.on_usage = None
        self.before_call = None
        self.heartbeat = None

    def generate_neighborhood(self, topic: str, counts: dict[str, int]) -> tuple[dict, dict]:
        parsed, usage = self._json(build_neighborhood_prompt(topic, counts), PROMPT_NEIGHBORHOOD)
        return _normalize_neighborhood(parsed, counts), usage

    def match_topics(self, candidates: list[dict]) -> tuple[dict, dict]:
        parsed, usage = self._json(build_sameness_prompt(candidates), PROMPT_SAMENESS)
        return _normalize_sameness(parsed), usage

    def _bill(self, meta: dict | None) -> dict:
        usage = usage_from_gemini_metadata(self.model, meta)
        sink = getattr(self, "on_usage", None)
        if callable(sink):
            sink(usage)
        return usage

    def _json(self, prompt: str, prompt_version: str) -> tuple[dict, dict]:
        if not self.api_key:
            raise generation_unavailable("GOOGLE_GEMINI_API_KEY is not configured", terminal=True)
        url = f"https://generativelanguage.googleapis.com/v1beta/models/{self.model}:generateContent"
        max_out = 3072
        body = {
            "contents": [{"role": "user", "parts": [{"text": prompt}]}],
            "generationConfig": {
                "temperature": self.temperature,
                "responseMimeType": "application/json",
                "maxOutputTokens": max_out,
                # Disable paid thinking tokens when the model supports it.
                "thinkingConfig": {"thinkingBudget": 0},
            },
        }
        logging.getLogger("httpx").setLevel(logging.WARNING)
        logging.getLogger("httpcore").setLevel(logging.WARNING)
        last_error: Exception | None = None
        last_usage: dict | None = None
        heartbeat = getattr(self, "heartbeat", None)
        before = getattr(self, "before_call", None)
        for attempt in range(1, 3):
            if callable(heartbeat):
                heartbeat()
            if callable(before):
                before(reserve_usd_for_call(self.model, max_out))
            try:
                with httpx.Client(timeout=90) as client:
                    response = client.post(url, json=body, headers={"x-goog-api-key": self.api_key})
                if response.status_code == 402:
                    raise generation_unavailable("The model account has no credits left", terminal=True)
                if response.status_code == 429:
                    raise generation_unavailable(
                        "Gemini rate or spend limit (429). Stopping to avoid burn.",
                        terminal=True,
                    )
                if response.status_code == 400 and "thinkingConfig" in body["generationConfig"]:
                    # Older model aliases may reject thinkingConfig; drop and retry once.
                    body["generationConfig"].pop("thinkingConfig", None)
                    continue
                response.raise_for_status()
                payload = response.json()
                # Bill from Gemini's usageMetadata even when JSON parse fails.
                last_usage = self._bill(payload.get("usageMetadata"))
                parsed = _parse_gemini_payload(payload)
                parsed.setdefault("schema_version", 1)
                parsed.setdefault("prompt_version", prompt_version)
                return parsed, last_usage
            except AppError:
                raise
            except (httpx.HTTPError, KeyError, json.JSONDecodeError, IndexError, ValueError) as exc:
                last_error = exc
                max_out = min(4096, 3072 + 1024 * attempt)
                body["generationConfig"]["maxOutputTokens"] = max_out
                logger.info(
                    "gemini neighborhood retry %s: %s (%s)",
                    attempt,
                    type(exc).__name__,
                    str(exc)[:160],
                )
        raise generation_unavailable("Gemini did not return valid JSON") from last_error


class OpenAINeighborhoodLLM:
    name = "openai"

    def __init__(self) -> None:
        settings = get_settings()
        self.api_key = settings.openai_api_key
        self.model = settings.openai_model
        self.temperature = settings.openai_temperature
        self.on_usage = None
        self.before_call = None
        self.heartbeat = None

    def generate_neighborhood(self, topic: str, counts: dict[str, int]) -> tuple[dict, dict]:
        parsed, usage = self._json(build_neighborhood_prompt(topic, counts), PROMPT_NEIGHBORHOOD)
        return _normalize_neighborhood(parsed, counts), usage

    def match_topics(self, candidates: list[dict]) -> tuple[dict, dict]:
        parsed, usage = self._json(build_sameness_prompt(candidates), PROMPT_SAMENESS)
        return _normalize_sameness(parsed), usage

    def _bill(self, usage_payload: dict | None) -> dict:
        usage = usage_from_openai_usage(self.model, usage_payload)
        sink = getattr(self, "on_usage", None)
        if callable(sink):
            sink(usage)
        return usage

    def _json(self, prompt: str, prompt_version: str) -> tuple[dict, dict]:
        if not self.api_key:
            raise generation_unavailable("OPENAI_API_KEY is not configured", terminal=True)
        url = "https://api.openai.com/v1/chat/completions"
        max_out = 3072
        body = {
            "model": self.model,
            "temperature": self.temperature,
            "max_tokens": max_out,
            "response_format": {"type": "json_object"},
            "messages": [
                {
                    "role": "system",
                    "content": "You return valid JSON objects only. No markdown fences.",
                },
                {"role": "user", "content": prompt},
            ],
        }
        logging.getLogger("httpx").setLevel(logging.WARNING)
        logging.getLogger("httpcore").setLevel(logging.WARNING)
        last_error: Exception | None = None
        heartbeat = getattr(self, "heartbeat", None)
        before = getattr(self, "before_call", None)
        for attempt in range(1, 3):
            if callable(heartbeat):
                heartbeat()
            if callable(before):
                before(reserve_usd_for_call(self.model, max_out))
            try:
                with httpx.Client(timeout=90) as client:
                    response = client.post(
                        url,
                        json=body,
                        headers={
                            "Authorization": f"Bearer {self.api_key}",
                            "Content-Type": "application/json",
                        },
                    )
                if response.status_code == 402:
                    raise generation_unavailable("The model account has no credits left", terminal=True)
                if response.status_code == 429:
                    raise generation_unavailable(
                        "OpenAI rate or spend limit (429). Stopping to avoid burn.",
                        terminal=True,
                    )
                response.raise_for_status()
                payload = response.json()
                usage = self._bill(payload.get("usage"))
                parsed = _parse_openai_payload(payload)
                parsed.setdefault("schema_version", 1)
                parsed.setdefault("prompt_version", prompt_version)
                return parsed, usage
            except AppError:
                raise
            except (httpx.HTTPError, KeyError, json.JSONDecodeError, IndexError, ValueError) as exc:
                last_error = exc
                max_out = min(4096, 3072 + 1024 * attempt)
                body["max_tokens"] = max_out
                logger.info(
                    "openai neighborhood retry %s: %s (%s)",
                    attempt,
                    type(exc).__name__,
                    str(exc)[:160],
                )
        raise generation_unavailable("OpenAI did not return valid JSON") from last_error


