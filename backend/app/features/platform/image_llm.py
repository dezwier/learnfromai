"""LLM contracts for shared topic images (Gemini Imagen / OpenAI Images)."""

from __future__ import annotations

import base64
import logging
from typing import Protocol

import httpx

from app.core.config import get_settings
from app.core.errors import generation_unavailable
from app.features.platform.llm_usage_pricing import (
    image_cost_usd,
    reserve_usd_for_image,
    usage_from_image_cost,
)
from app.features.platform.neighborhood_llm import resolve_llm_provider

logger = logging.getLogger(__name__)

PROMPT_IMAGE = "topic_image_v1"

# 1×1 PNG used by the fake provider in tests.
_FAKE_PNG = base64.b64decode(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
)


class ImageLLM(Protocol):
    name: str

    def generate_image(self, name: str, description: str | None) -> tuple[bytes, dict]: ...


def build_topic_image_prompt(name: str, description: str | None) -> str:
    topic = (name or "Topic").strip() or "Topic"
    desc = (description or "").strip()
    subject = f"{topic}."
    if desc:
        subject = f"{topic}: {desc}"
    return (
        "Create one iconic square image that represents the learning topic below. "
        "Style: photorealistic, mature editorial photography, clean single-subject "
        "composition, soft natural light, shallow depth of field, no text, no logos, "
        "no UI, no watermarks, no collage, no borders. "
        "Prefer a realistic mature look unless the topic clearly demands another medium "
        "(myth, fantasy, abstract math, cartoon characters, etc.). "
        f"Topic: {subject}"
    )


class FakeImageLLM:
    name = "fake"

    def generate_image(self, name: str, description: str | None) -> tuple[bytes, dict]:
        _ = (name, description)
        return _FAKE_PNG, usage_from_image_cost("fake-image", 0.0)


class GeminiImageLLM:
    name = "gemini"

    def __init__(self) -> None:
        settings = get_settings()
        self.api_key = settings.google_gemini_api_key
        self.model = settings.gemini_image_model
        self.on_usage = None
        self.before_call = None
        self.heartbeat = None

    def generate_image(self, name: str, description: str | None) -> tuple[bytes, dict]:
        if not self.api_key:
            raise generation_unavailable("GOOGLE_GEMINI_API_KEY is not configured", terminal=True)
        prompt = build_topic_image_prompt(name, description)
        url = f"https://generativelanguage.googleapis.com/v1beta/models/{self.model}:predict"
        body = {
            "instances": [{"prompt": prompt}],
            "parameters": {
                "sampleCount": 1,
                "aspectRatio": "1:1",
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
            response.raise_for_status()
            payload = response.json()
        except generation_unavailable:
            raise
        except httpx.HTTPError as exc:
            raise generation_unavailable("Gemini image generation failed") from exc

        png = _extract_gemini_image(payload)
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

    def generate_image(self, name: str, description: str | None) -> tuple[bytes, dict]:
        if not self.api_key:
            raise generation_unavailable("OPENAI_API_KEY is not configured", terminal=True)
        prompt = build_topic_image_prompt(name, description)
        url = "https://api.openai.com/v1/images/generations"
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
            response.raise_for_status()
            payload = response.json()
        except generation_unavailable:
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


def _extract_gemini_image(payload: dict) -> bytes:
    predictions = payload.get("predictions") if isinstance(payload, dict) else None
    if not isinstance(predictions, list) or not predictions:
        raise generation_unavailable("Gemini returned no image predictions")
    first = predictions[0] if isinstance(predictions[0], dict) else {}
    b64 = first.get("bytesBase64Encoded") or first.get("image") or ""
    if not b64:
        raise generation_unavailable("Gemini image payload missing bytes")
    try:
        return base64.b64decode(b64)
    except Exception as exc:
        raise generation_unavailable("Gemini image bytes were invalid") from exc


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
