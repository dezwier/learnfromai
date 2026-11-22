"""LLM contracts for shared topic images (Gemini / OpenAI Images)."""

from __future__ import annotations

import base64
import logging
from typing import Protocol

import httpx

from app.core.config import get_settings
from app.core.errors import AppError, generation_unavailable
from app.features.platform.llm_usage_pricing import (
    image_cost_usd,
    reserve_usd_for_image,
    usage_from_image_cost,
)
from app.features.platform.neighborhood_llm import resolve_llm_provider

logger = logging.getLogger(__name__)

PROMPT_IMAGE = "topic_image_v3"

# 1×1 PNG used by the fake provider in tests.
_FAKE_PNG = base64.b64decode(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
)


_NO_TEXT = (
    "CRITICAL — TEXT-FREE IMAGE: "
    "Show zero writing in the frame. No letters, words, numbers, digits, captions, "
    "titles, subtitles, labels, annotations, callouts, arrows with words, sticky notes, "
    "whiteboard writing, chalk writing, book pages with readable prose, posters, "
    "street signs, product packaging text, logos, watermarks, UI chrome, or typography "
    "of any kind. Do not render the topic name or learning title as text. "
    "Do not draw equations, formulas, symbols-as-labels, charts with axis labels, "
    "or diagrams with named boxes — convey those ideas with concrete objects, scenes, "
    "light, gesture, and metaphor instead. "
    "The only exception is when the learning subject IS the craft of writing itself "
    "(e.g. the art of calligraphy, illuminated manuscripts as artifacts) and even then "
    "keep glyphs abstract/illegible rather than spelling real words. "
    "If unsure, omit all text. "
)

_IMAGE_STYLE = (
    "Style: photorealistic, mature editorial photography, clean single-subject "
    "composition, soft natural light, shallow depth of field, no logos, no UI, "
    "no watermarks, no collage, no borders. "
    "Prefer a realistic mature look unless the topic clearly demands another medium "
    "(myth, fantasy, abstract concept, cartoon characters, etc.). "
)


class ImageLLM(Protocol):
    name: str

    def generate_image(
        self,
        name: str,
        description: str | None,
        *,
        prompt: str | None = None,
    ) -> tuple[bytes, dict]: ...


def build_topic_image_prompt(name: str, description: str | None) -> str:
    topic = (name or "Topic").strip() or "Topic"
    desc = (description or "").strip()
    subject = f"{topic}."
    if desc:
        subject = f"{topic}: {desc}"
    return (
        f"{_NO_TEXT}"
        "Create one iconic square image that represents the learning topic below "
        "using only visual imagery — no written language in the picture. "
        f"{_IMAGE_STYLE}"
        f"Topic (for meaning only, never letter it into the image): {subject} "
        f"{_NO_TEXT}"
    )


def build_pack_image_prompt(
    name: str,
    description: str | None,
    *,
    learn_title: str,
    learn_markdown: str,
) -> str:
    topic = (name or "Topic").strip() or "Topic"
    desc = (description or "").strip()
    title = (learn_title or "").strip()
    bit = (learn_markdown or "").strip()
    if len(bit) > 600:
        bit = bit[:600].rstrip() + "…"
    subject_lines = [f"Topic (meaning only): {topic}."]
    if desc:
        subject_lines.append(f"Topic context (meaning only): {desc}")
    if title:
        subject_lines.append(f"Learning bit title (meaning only, never print it): {title}")
    if bit:
        subject_lines.append(
            f"Learning bit (conceptual guidance only — do not copy any of this prose "
            f"or its terms as text in the image): {bit}"
        )
    return (
        f"{_NO_TEXT}"
        "Create one square image that supports the atomic learning below "
        "(illustrate the specific idea with a scene or object, not a generic topic icon, "
        "and not a titled poster or textbook page). "
        f"{_IMAGE_STYLE}"
        + " ".join(subject_lines)
        + f" {_NO_TEXT}"
    )


class FakeImageLLM:
    name = "fake"

    def generate_image(
        self,
        name: str,
        description: str | None,
        *,
        prompt: str | None = None,
    ) -> tuple[bytes, dict]:
        _ = (name, description, prompt)
        return _FAKE_PNG, usage_from_image_cost("fake-image", 0.0)


class GeminiImageLLM:
    """Native Gemini image models (Imagen predict API is shut down)."""

    name = "gemini"

    def __init__(self) -> None:
        settings = get_settings()
        self.api_key = settings.google_gemini_api_key
        self.model = settings.gemini_image_model
        self.on_usage = None
        self.before_call = None
        self.heartbeat = None

    def generate_image(
        self,
        name: str,
        description: str | None,
        *,
        prompt: str | None = None,
    ) -> tuple[bytes, dict]:
        if not self.api_key:
            raise generation_unavailable("GOOGLE_GEMINI_API_KEY is not configured", terminal=True)
        prompt = prompt or build_topic_image_prompt(name, description)
        url = f"https://generativelanguage.googleapis.com/v1beta/models/{self.model}:generateContent"
        body = {
            "contents": [{"role": "user", "parts": [{"text": prompt}]}],
            "generationConfig": {
                "responseModalities": ["IMAGE"],
                "imageConfig": {"aspectRatio": "1:1", "imageSize": "1K"},
            },
        }
        logging.getLogger("httpx").setLevel(logging.WARNING)
        logging.getLogger("httpcore").setLevel(logging.WARNING)
        heartbeat = getattr(self, "heartbeat", None)
        before = getattr(self, "before_call", None)
        if callable(heartbeat):
            heartbeat()
        if callable(before):
            before(reserve_usd_for_image(self.model))
        try:
            with httpx.Client(timeout=120) as client:
                response = client.post(url, json=body, headers={"x-goog-api-key": self.api_key})
            if response.status_code == 402:
                raise generation_unavailable("The model account has no credits left", terminal=True)
            if response.status_code == 429:
                raise generation_unavailable(
                    "Gemini rate or spend limit (429). Stopping to avoid burn.",
                    terminal=True,
                )
            if response.status_code >= 400:
                detail = _http_error_detail(response)
                terminal = response.status_code in {400, 401, 403, 404}
                raise generation_unavailable(
                    f"Gemini image generation failed ({response.status_code}): {detail}",
                    terminal=terminal,
                )
            payload = response.json()
        except AppError:
            raise
        except httpx.HTTPError as exc:
            raise generation_unavailable("Gemini image generation failed") from exc

        png = _extract_gemini_native_image(payload)
        usage = usage_from_image_cost(self.model, image_cost_usd(self.model))
        sink = getattr(self, "on_usage", None)
        if callable(sink):
            sink(usage)
        return png, usage


class OpenAIImageLLM:
    name = "openai"

    def __init__(self) -> None:
        settings = get_settings()
        self.api_key = settings.openai_api_key
        self.model = settings.openai_image_model
        self.quality = settings.openai_image_quality
        self.size = settings.openai_image_size
        self.on_usage = None
        self.before_call = None
        self.heartbeat = None

    def generate_image(
        self,
        name: str,
        description: str | None,
        *,
        prompt: str | None = None,
    ) -> tuple[bytes, dict]:
        if not self.api_key:
            raise generation_unavailable("OPENAI_API_KEY is not configured", terminal=True)
        prompt = prompt or build_topic_image_prompt(name, description)
        url = "https://api.openai.com/v1/images/generations"
        # GPT image models always return b64_json; do not send response_format.
        body = {
            "model": self.model,
            "prompt": prompt,
            "n": 1,
            "size": self.size,
            "quality": self.quality,
        }
        logging.getLogger("httpx").setLevel(logging.WARNING)
        logging.getLogger("httpcore").setLevel(logging.WARNING)
        heartbeat = getattr(self, "heartbeat", None)
        before = getattr(self, "before_call", None)
        if callable(heartbeat):
            heartbeat()
        if callable(before):
            before(reserve_usd_for_image(self.model, quality=self.quality))
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
                detail = _http_error_detail(response)
                terminal = response.status_code in {400, 401, 403, 404}
                raise generation_unavailable(
                    f"OpenAI image generation failed ({response.status_code}): {detail}",
                    terminal=terminal,
                )
            payload = response.json()
        except AppError:
            raise
        except httpx.HTTPError as exc:
            raise generation_unavailable("OpenAI image generation failed") from exc

        png = _extract_openai_image(payload)
        usage = usage_from_image_cost(
            self.model,
            image_cost_usd(self.model, quality=self.quality),
        )
        sink = getattr(self, "on_usage", None)
        if callable(sink):
            sink(usage)
        return png, usage


def get_image_llm(provider: str | None = None) -> ImageLLM:
    choice = resolve_llm_provider(provider)
    if choice == "fake":
        return FakeImageLLM()
    if choice == "openai":
        return OpenAIImageLLM()
    return GeminiImageLLM()


def _http_error_detail(response: httpx.Response) -> str:
    try:
        payload = response.json()
    except Exception:
        text = (response.text or "").strip()
        return text[:240] or response.reason_phrase
    if isinstance(payload, dict):
        err = payload.get("error")
        if isinstance(err, dict):
            message = err.get("message") or err.get("code")
            if message:
                return str(message)[:240]
        message = payload.get("message")
        if message:
            return str(message)[:240]
    return str(payload)[:240]


def _extract_gemini_native_image(payload: dict) -> bytes:
    candidates = payload.get("candidates") if isinstance(payload, dict) else None
    if not isinstance(candidates, list) or not candidates:
        raise generation_unavailable("Gemini returned no image candidates")
    content = candidates[0].get("content") if isinstance(candidates[0], dict) else None
    parts = content.get("parts") if isinstance(content, dict) else None
    if not isinstance(parts, list):
        raise generation_unavailable("Gemini image payload missing parts")
    for part in parts:
        if not isinstance(part, dict):
            continue
        inline = part.get("inlineData") or part.get("inline_data")
        if not isinstance(inline, dict):
            continue
        b64 = inline.get("data") or ""
        if not b64:
            continue
        try:
            return base64.b64decode(b64)
        except Exception as exc:
            raise generation_unavailable("Gemini image bytes were invalid") from exc
    raise generation_unavailable("Gemini image payload missing inline image data")


def _extract_openai_image(payload: dict) -> bytes:
    data = payload.get("data") if isinstance(payload, dict) else None
    if not isinstance(data, list) or not data:
        raise generation_unavailable("OpenAI returned no image data")
    first = data[0] if isinstance(data[0], dict) else {}
    b64 = first.get("b64_json") or ""
    if not b64:
        raise generation_unavailable("OpenAI image payload missing b64_json")
    try:
        return base64.b64decode(b64)
    except Exception as exc:
        raise generation_unavailable("OpenAI image bytes were invalid") from exc
