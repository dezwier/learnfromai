"""LLM contracts for shared tile content (learn / example / check)."""

from __future__ import annotations

import json
import logging
from typing import Protocol

import httpx

from app.core.config import get_settings
from app.core.errors import AppError, generation_unavailable
from app.features.content.models import CONTENT_KINDS
from app.features.platform.llm_usage_pricing import (
    reserve_usd_for_call,
    usage_from_gemini_metadata,
    usage_from_openai_usage,
)
from app.features.platform.neighborhood_llm import (
    _parse_gemini_payload,
    _parse_openai_payload,
    _usage,
    resolve_llm_provider,
)

logger = logging.getLogger(__name__)

PROMPT_CONTENT = "content_bits_v1"


class ContentLLM(Protocol):
    name: str

    def generate_bits(
        self,
        name: str,
        description: str | None,
        neighbor_titles: list[str],
    ) -> tuple[dict, dict]: ...


def build_content_prompt(name: str, description: str | None, neighbor_titles: list[str]) -> str:
    return (
        "Create short learning content for one topic. Return JSON only with keys "
        "learn, example, check. "
        "learn and example are objects {title, markdown} with concise Markdown "
        "(a few short paragraphs max). "
        "check is {question, choices, answer_index, explanation} where choices is an array "
        "of exactly 4 short strings, answer_index is 0..3, and explanation is one short sentence. "
        "Do not invent prerequisites. Keep language clear and standalone.\n"
        + json.dumps(
            {
                "topic": name,
                "description": description or "",
                "neighbors": neighbor_titles[:12],
            }
        )
    )


class FakeContentLLM:
    name = "fake"

    def generate_bits(
        self,
        name: str,
        description: str | None,
        neighbor_titles: list[str],
    ) -> tuple[dict, dict]:
        topic = (name or "Topic").strip() or "Topic"
        desc = (description or "").strip()
        neighbors = ", ".join(neighbor_titles[:4]) if neighbor_titles else "related ideas"
        payload = {
            "learn": {
                "title": f"What is {topic}?",
                "markdown": (
                    f"**{topic}** is a topic you can learn in short steps. "
                    f"{desc or f'It sits near {neighbors}.'} "
                    "Focus on the core idea before details."
                ),
            },
            "example": {
                "title": f"{topic} in practice",
                "markdown": (
                    f"Imagine explaining **{topic}** to a curious friend in two sentences: "
                    f"start with the plain meaning"
                    f"{f' ({desc})' if desc else ''}, then name one concrete situation where it shows up."
                ),
            },
            "check": {
                "question": f"Which statement best fits {topic}?",
                "choices": [
                    f"{topic} is a learning topic with a clear core idea.",
                    f"{topic} is unrelated to anything nearby.",
                    f"{topic} has no practical uses.",
                    f"{topic} only exists as a random label.",
                ],
                "answer_index": 0,
                "explanation": f"The first choice matches how we introduce {topic}.",
            },
        }
        return normalize_bits(payload), _usage("fake", 20, 40)


class GeminiContentLLM:
    name = "gemini"

    def __init__(self) -> None:
        settings = get_settings()
        self.api_key = settings.google_gemini_api_key
        self.model = settings.gemini_model
        self.temperature = settings.gemini_temperature
        self.on_usage = None
        self.before_call = None
        self.heartbeat = None

    def generate_bits(
        self,
        name: str,
        description: str | None,
        neighbor_titles: list[str],
    ) -> tuple[dict, dict]:
        parsed, usage = self._json(build_content_prompt(name, description, neighbor_titles))
        return normalize_bits(parsed), usage

    def _bill(self, meta: dict | None) -> dict:
        usage = usage_from_gemini_metadata(self.model, meta)
        sink = getattr(self, "on_usage", None)
        if callable(sink):
            sink(usage)
        return usage

    def _json(self, prompt: str) -> tuple[dict, dict]:
        if not self.api_key:
            raise generation_unavailable("GOOGLE_GEMINI_API_KEY is not configured", terminal=True)
        url = f"https://generativelanguage.googleapis.com/v1beta/models/{self.model}:generateContent"
        max_out = 2048
        body = {
            "contents": [{"role": "user", "parts": [{"text": prompt}]}],
            "generationConfig": {
                "temperature": self.temperature,
                "responseMimeType": "application/json",
                "maxOutputTokens": max_out,
                "thinkingConfig": {"thinkingBudget": 0},
            },
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
                    response = client.post(url, json=body, headers={"x-goog-api-key": self.api_key})
                if response.status_code == 402:
                    raise generation_unavailable("The model account has no credits left", terminal=True)
                if response.status_code == 429:
                    raise generation_unavailable(
                        "Gemini rate or spend limit (429). Stopping to avoid burn.",
                        terminal=True,
                    )
                if response.status_code == 400 and "thinkingConfig" in body["generationConfig"]:
                    body["generationConfig"].pop("thinkingConfig", None)
                    continue
                response.raise_for_status()
                payload = response.json()
                usage = self._bill(payload.get("usageMetadata"))
                parsed = _parse_gemini_payload(payload)
                parsed.setdefault("schema_version", 1)
                parsed.setdefault("prompt_version", PROMPT_CONTENT)
                return parsed, usage
            except AppError:
                raise
            except (httpx.HTTPError, KeyError, json.JSONDecodeError, IndexError, ValueError) as exc:
                last_error = exc
                max_out = min(3072, 2048 + 512 * attempt)
                body["generationConfig"]["maxOutputTokens"] = max_out
                logger.info(
                    "gemini content retry %s: %s (%s)",
                    attempt,
                    type(exc).__name__,
                    str(exc)[:160],
                )
        raise generation_unavailable("Gemini did not return valid content JSON") from last_error


class OpenAIContentLLM:
    name = "openai"

    def __init__(self) -> None:
        settings = get_settings()
        self.api_key = settings.openai_api_key
        self.model = settings.openai_model
        self.temperature = settings.openai_temperature
        self.on_usage = None
        self.before_call = None
        self.heartbeat = None

    def generate_bits(
        self,
        name: str,
        description: str | None,
        neighbor_titles: list[str],
    ) -> tuple[dict, dict]:
        parsed, usage = self._json(build_content_prompt(name, description, neighbor_titles))
        return normalize_bits(parsed), usage

    def _bill(self, usage_payload: dict | None) -> dict:
        usage = usage_from_openai_usage(self.model, usage_payload)
        sink = getattr(self, "on_usage", None)
        if callable(sink):
            sink(usage)
        return usage

    def _json(self, prompt: str) -> tuple[dict, dict]:
        if not self.api_key:
            raise generation_unavailable("OPENAI_API_KEY is not configured", terminal=True)
        url = "https://api.openai.com/v1/chat/completions"
        max_out = 2048
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
                parsed.setdefault("prompt_version", PROMPT_CONTENT)
                return parsed, usage
            except AppError:
                raise
            except (httpx.HTTPError, KeyError, json.JSONDecodeError, IndexError, ValueError) as exc:
                last_error = exc
                max_out = min(3072, 2048 + 512 * attempt)
                body["max_tokens"] = max_out
                logger.info(
                    "openai content retry %s: %s (%s)",
                    attempt,
                    type(exc).__name__,
                    str(exc)[:160],
                )
        raise generation_unavailable("OpenAI did not return valid content JSON") from last_error


def get_content_llm(provider: str | None = None) -> ContentLLM:
    choice = resolve_llm_provider(provider)
    if choice == "fake":
        return FakeContentLLM()
    if choice == "openai":
        return OpenAIContentLLM()
    return GeminiContentLLM()


def normalize_bits(raw: dict) -> dict:
    """Validate and normalize learn / example / check bodies."""
    if not isinstance(raw, dict):
        raise ValueError("Content JSON root must be an object")
    out: dict[str, dict] = {}
    for kind in ("learn", "example"):
        row = raw.get(kind) if isinstance(raw.get(kind), dict) else {}
        title = str(row.get("title") or "").strip() or None
        markdown = str(row.get("markdown") or row.get("text") or "").strip()
        if not markdown:
            raise ValueError(f"Content bit {kind!r} is missing markdown")
        out[kind] = {"title": title, "markdown": markdown}
    check = raw.get("check") if isinstance(raw.get("check"), dict) else {}
    question = str(check.get("question") or "").strip()
    choices_raw = check.get("choices") if isinstance(check.get("choices"), list) else []
    choices = [str(item).strip() for item in choices_raw if str(item).strip()]
    if len(choices) < 4:
        raise ValueError("Check must include 4 choices")
    choices = choices[:4]
    try:
        answer_index = int(check.get("answer_index"))
    except (TypeError, ValueError) as exc:
        raise ValueError("Check answer_index must be an integer") from exc
    if answer_index < 0 or answer_index > 3:
        raise ValueError("Check answer_index must be 0..3")
    explanation = str(check.get("explanation") or "").strip() or None
    if not question:
        raise ValueError("Check is missing question")
    out["check"] = {
        "question": question,
        "choices": choices,
        "answer_index": answer_index,
        "explanation": explanation,
    }
    for kind in CONTENT_KINDS:
        if kind not in out:
            raise ValueError(f"Missing content bit {kind!r}")
    return out


__all__ = [
    "ContentLLM",
    "FakeContentLLM",
    "GeminiContentLLM",
    "OpenAIContentLLM",
    "PROMPT_CONTENT",
    "build_content_prompt",
    "get_content_llm",
    "normalize_bits",
]
