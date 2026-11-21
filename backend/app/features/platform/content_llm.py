"""LLM contracts for shared tile content (atomic learning packs)."""

from __future__ import annotations

import json
import logging
from typing import Protocol

import httpx

from app.core.config import get_settings
from app.core.errors import AppError, generation_unavailable
from app.features.content.models import CHECK_KINDS, CHECK_TYPES, CONTENT_KINDS
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
from app.features.platform.openai_chat import openai_chat_body, set_openai_max_out

logger = logging.getLogger(__name__)

PROMPT_CONTENT = "content_bits_v5"


class ContentLLM(Protocol):
    name: str

    def generate_bits(
        self,
        name: str,
        description: str | None,
        neighbor_titles: list[str],
        *,
        kinds: list[str] | None = None,
        existing_checks: dict[str, dict] | None = None,
        existing_packs: list[dict] | None = None,
        pack_index: int = 1,
    ) -> tuple[dict, dict]: ...


def build_content_prompt(
    name: str,
    description: str | None,
    neighbor_titles: list[str],
    *,
    kinds: list[str] | None = None,
    existing_checks: dict[str, dict] | None = None,
    existing_packs: list[dict] | None = None,
    pack_index: int = 1,
) -> str:
    required = [k for k in (kinds or list(CONTENT_KINDS)) if k in CONTENT_KINDS]
    if not required:
        required = list(CONTENT_KINDS)
    checks_needed = [k for k in required if k in CHECK_KINDS]
    need_learn = "learn" in required

    parts = [
        f"Write one atomic learning for {name}: one interesting learning bit about this topic. "
        "Return JSON only with keys: "
        + ", ".join(required)
        + ".\n\n"
        "Shape:\n"
        "- learn: one short, standalone atomic learning bit — concrete, interesting, worth knowing\n"
        "- three tests (check1–check3): genuinely useful checks of that same bit\n\n"
        "Rules:\n"
        "- Stay on this topic only.\n"
        "- Do not teach neighboring topics.\n"
        "- Do not overlap other atomic learnings already written for this topic.\n"
        "- Never mention neighbors, other learnings, or these rules in the learner-facing text.\n"
        "- The learning bit must stand alone (no “as above”, no fluff, no generic intro).\n"
        "- Tests must stand alone and be worth asking — precise, not trivia or paraphrases of each other.\n"
    ]
    if need_learn:
        parts.append(
            "learn = {title, markdown}. Title: short (a few words, not a full sentence). "
            "Markdown: a few short paragraphs max. "
            "Make it interesting: a sharp fact, mechanism, or distinction someone is glad they learned.\n"
        )
    if checks_needed:
        parts.append(
            "Each check is one of:\n"
            "- mc: {type:'mc', question, choices (exactly 4 short strings), answer_index 0..3, explanation}\n"
            "- true_false: {type:'true_false', statement, answer (boolean), explanation}\n"
            "- cloze: {type:'cloze', prompt (with ___), answer, aliases (optional), explanation}; "
            "answer and aliases must each be exactly one word or one number (no phrases)\n"
            "Mix types when useful. Wrong answers should be plausible near-misses.\n"
        )
        if existing_checks:
            parts.append(
                "Avoid duplicating these existing checks in this pack: "
                + json.dumps(existing_checks)
                + "\n"
            )
    if existing_packs:
        parts.append(
            "Other packs on this topic (do not repeat): "
            + json.dumps(existing_packs)
            + "\n"
        )
    if neighbor_titles:
        parts.append(
            "Neighbor topics (do not teach): "
            + json.dumps(neighbor_titles[:12])
            + "\n"
        )
    parts.append(
        "\n"
        + json.dumps(
            {
                "topic": name,
                "description": description or "",
                "pack_index": pack_index,
                "required_keys": required,
            }
        )
    )
    return "".join(parts)


class FakeContentLLM:
    name = "fake"

    def generate_bits(
        self,
        name: str,
        description: str | None,
        neighbor_titles: list[str],
        *,
        kinds: list[str] | None = None,
        existing_checks: dict[str, dict] | None = None,
        existing_packs: list[dict] | None = None,
        pack_index: int = 1,
    ) -> tuple[dict, dict]:
        topic = (name or "Topic").strip() or "Topic"
        desc = (description or "").strip()
        neighbors = ", ".join(neighbor_titles[:4]) if neighbor_titles else "related ideas"
        required = [k for k in (kinds or list(CONTENT_KINDS)) if k in CONTENT_KINDS]
        facet = f"pack {pack_index}" if pack_index > 1 else "core idea"
        payload: dict = {}
        if "learn" in required:
            payload["learn"] = {
                "title": topic if pack_index == 1 else facet.title(),
                "markdown": (
                    f"**{topic}** ({facet}): "
                    f"{desc or 'One precise idea you can use right away.'} "
                    f"Hold onto that single idea before branching toward {neighbors}."
                ),
            }
        if pack_index == 1:
            check_templates = {
                "check1": {
                    "type": "mc",
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
                "check2": {
                    "type": "mc",
                    "question": f"What is a useful next step when learning {topic}?",
                    "choices": [
                        f"Start from the core idea of {topic}, then add one concrete example.",
                        f"Ignore {topic} and memorize unrelated trivia.",
                        f"Assume {topic} has no connection to nearby ideas.",
                        f"Skip explanations and only collect buzzwords about {topic}.",
                    ],
                    "answer_index": 0,
                    "explanation": (
                        f"Building from the core idea with an example is the useful next step for {topic}."
                    ),
                },
                "check3": {
                    "type": "mc",
                    "question": f"Which claim about {topic} is weakest?",
                    "choices": [
                        f"{topic} can be explained in plain language without jargon.",
                        f"{topic} is only a random string of letters with no meaning.",
                        f"{topic} often sits near related ideas in a knowledge map.",
                        f"{topic} can be checked with a short multiple-choice question.",
                    ],
                    "answer_index": 1,
                    "explanation": f"Calling {topic} meaningless is the weakest claim.",
                },
            }
        else:
            check_templates = {
                "check1": {
                    "type": "true_false",
                    "statement": f"{topic} can be learned in short standalone steps.",
                    "answer": True,
                    "explanation": f"Atomic packs are designed for short steps about {topic}.",
                },
                "check2": {
                    "type": "cloze",
                    "prompt": f"A pack about {topic} always includes exactly ___ checks.",
                    "answer": "3",
                    "aliases": ["three"],
                    "explanation": "Each pack has three test bits.",
                },
                "check3": {
                    "type": "mc",
                    "question": f"Which focus fits a later pack about {topic}?",
                    "choices": [
                        f"A different facet of {topic} not covered yet.",
                        f"A full course on every neighbor of {topic}.",
                        f"Ignoring {topic} entirely.",
                        f"Only memorizing the word {topic}.",
                    ],
                    "answer_index": 0,
                    "explanation": f"Later packs deepen {topic} without leaving the topic.",
                },
            }
        for kind in CHECK_KINDS:
            if kind not in required:
                continue
            payload[kind] = check_templates[kind]
        return normalize_bits(payload, required_kinds=required), _usage("fake", 20, 80)


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
        *,
        kinds: list[str] | None = None,
        existing_checks: dict[str, dict] | None = None,
        existing_packs: list[dict] | None = None,
        pack_index: int = 1,
    ) -> tuple[dict, dict]:
        required = [k for k in (kinds or list(CONTENT_KINDS)) if k in CONTENT_KINDS]
        parsed, usage = self._json(
            build_content_prompt(
                name,
                description,
                neighbor_titles,
                kinds=required,
                existing_checks=existing_checks,
                existing_packs=existing_packs,
                pack_index=pack_index,
            )
        )
        return normalize_bits(parsed, required_kinds=required), usage

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
        max_out = 3072
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
                max_out = min(4096, 3072 + 512 * attempt)
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
        *,
        kinds: list[str] | None = None,
        existing_checks: dict[str, dict] | None = None,
        existing_packs: list[dict] | None = None,
        pack_index: int = 1,
    ) -> tuple[dict, dict]:
        required = [k for k in (kinds or list(CONTENT_KINDS)) if k in CONTENT_KINDS]
        parsed, usage = self._json(
            build_content_prompt(
                name,
                description,
                neighbor_titles,
                kinds=required,
                existing_checks=existing_checks,
                existing_packs=existing_packs,
                pack_index=pack_index,
            )
        )
        return normalize_bits(parsed, required_kinds=required), usage

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
        # Reasoning models spend completion budget on hidden tokens; keep headroom.
        max_out = 8192
        body = openai_chat_body(
            model=self.model,
            max_out=max_out,
            temperature=self.temperature,
            response_format={"type": "json_object"},
            messages=[
                {
                    "role": "system",
                    "content": "You return valid JSON objects only. No markdown fences.",
                },
                {"role": "user", "content": prompt},
            ],
        )
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
                with httpx.Client(timeout=120) as client:
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
                if response.status_code >= 400:
                    logger.info(
                        "openai content http %s: %s",
                        response.status_code,
                        (response.text or "")[:400],
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
                max_out = min(12288, 8192 + 1024 * attempt)
                set_openai_max_out(body, max_out)
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


def _normalize_mc(check: dict, *, kind: str) -> dict:
    question = str(check.get("question") or "").strip()
    choices_raw = check.get("choices") if isinstance(check.get("choices"), list) else []
    choices = [str(item).strip() for item in choices_raw if str(item).strip()]
    if len(choices) < 4:
        raise ValueError(f"{kind} must include 4 choices")
    choices = choices[:4]
    try:
        answer_index = int(check.get("answer_index"))
    except (TypeError, ValueError) as exc:
        raise ValueError(f"{kind} answer_index must be an integer") from exc
    if answer_index < 0 or answer_index > 3:
        raise ValueError(f"{kind} answer_index must be 0..3")
    explanation = str(check.get("explanation") or "").strip() or None
    if not question:
        raise ValueError(f"{kind} is missing question")
    return {
        "type": "mc",
        "question": question,
        "choices": choices,
        "answer_index": answer_index,
        "explanation": explanation,
    }


def _normalize_true_false(check: dict, *, kind: str) -> dict:
    statement = str(check.get("statement") or check.get("question") or "").strip()
    if not statement:
        raise ValueError(f"{kind} is missing statement")
    raw = check.get("answer")
    if isinstance(raw, bool):
        answer = raw
    elif isinstance(raw, str) and raw.strip().lower() in {"true", "false"}:
        answer = raw.strip().lower() == "true"
    elif raw in (0, 1):
        answer = bool(raw)
    else:
        raise ValueError(f"{kind} answer must be a boolean")
    explanation = str(check.get("explanation") or "").strip() or None
    return {
        "type": "true_false",
        "statement": statement,
        "answer": answer,
        "explanation": explanation,
    }


def _is_single_cloze_token(value: str) -> bool:
    """Cloze answers must be one word or one number (no spaces/phrases)."""
    text = value.strip()
    if not text or any(ch.isspace() for ch in text):
        return False
    return True


def _normalize_cloze(check: dict, *, kind: str) -> dict:
    prompt = str(check.get("prompt") or check.get("question") or "").strip()
    answer = str(check.get("answer") or "").strip()
    if not prompt:
        raise ValueError(f"{kind} is missing prompt")
    if not answer:
        raise ValueError(f"{kind} is missing answer")
    if not _is_single_cloze_token(answer):
        raise ValueError(f"{kind} answer must be a single word or number")
    aliases_raw = check.get("aliases") if isinstance(check.get("aliases"), list) else []
    aliases: list[str] = []
    for item in aliases_raw:
        alias = str(item).strip()
        if not alias:
            continue
        if not _is_single_cloze_token(alias):
            raise ValueError(f"{kind} aliases must each be a single word or number")
        aliases.append(alias)
    explanation = str(check.get("explanation") or "").strip() or None
    return {
        "type": "cloze",
        "prompt": prompt,
        "answer": answer,
        "aliases": aliases,
        "explanation": explanation,
    }


def _normalize_check(raw: object, *, kind: str) -> dict:
    check = raw if isinstance(raw, dict) else {}
    raw_type = str(check.get("type") or "").strip().lower()
    if not raw_type:
        # Legacy bodies without type are multiple-choice.
        if "choices" in check or "answer_index" in check:
            raw_type = "mc"
        elif "statement" in check or isinstance(check.get("answer"), bool):
            raw_type = "true_false"
        elif "prompt" in check:
            raw_type = "cloze"
        else:
            raw_type = "mc"
    if raw_type not in CHECK_TYPES:
        raise ValueError(f"{kind} type must be one of {CHECK_TYPES}")
    if raw_type == "mc":
        return _normalize_mc(check, kind=kind)
    if raw_type == "true_false":
        return _normalize_true_false(check, kind=kind)
    return _normalize_cloze(check, kind=kind)


def normalize_bits(raw: dict, *, required_kinds: list[str] | None = None) -> dict:
    """Validate and normalize requested learn / check bodies."""
    if not isinstance(raw, dict):
        raise ValueError("Content JSON root must be an object")
    required = [k for k in (required_kinds or list(CONTENT_KINDS)) if k in CONTENT_KINDS]
    out: dict[str, dict] = {}
    if "learn" in required:
        row = raw.get("learn") if isinstance(raw.get("learn"), dict) else {}
        title = str(row.get("title") or "").strip() or None
        markdown = str(row.get("markdown") or row.get("text") or "").strip()
        if not markdown:
            raise ValueError("Content bit 'learn' is missing markdown")
        out["learn"] = {"title": title, "markdown": markdown}
    # Accept legacy "check" as check1 when generating check1.
    if "check1" in required and "check1" not in raw and isinstance(raw.get("check"), dict):
        raw = {**raw, "check1": raw["check"]}
    for kind in CHECK_KINDS:
        if kind not in required:
            continue
        out[kind] = _normalize_check(raw.get(kind), kind=kind)
    for kind in required:
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
