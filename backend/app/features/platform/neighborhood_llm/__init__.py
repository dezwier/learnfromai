"""LLM contracts for neighborhood generation and topic sameness."""

from __future__ import annotations

from app.features.platform.neighborhood_llm.core import (
    BUCKETS,
    PROMPT_NEIGHBORHOOD,
    PROMPT_SAMENESS,
    NeighborhoodLLM,
    _parse_gemini_payload,
    _parse_openai_payload,
    _usage,
    build_neighborhood_prompt,
    build_sameness_prompt,
    get_neighborhood_llm,
    normalize_llm_provider,
    parse_uuid,
    resolve_llm_provider,
)
from app.features.platform.neighborhood_llm.providers import (
    FakeNeighborhoodLLM,
    GeminiNeighborhoodLLM,
    OpenAINeighborhoodLLM,
)

__all__ = [
    "BUCKETS",
    "PROMPT_NEIGHBORHOOD",
    "PROMPT_SAMENESS",
    "FakeNeighborhoodLLM",
    "GeminiNeighborhoodLLM",
    "NeighborhoodLLM",
    "OpenAINeighborhoodLLM",
    "_parse_gemini_payload",
    "_parse_openai_payload",
    "_usage",
    "build_neighborhood_prompt",
    "build_sameness_prompt",
    "get_neighborhood_llm",
    "normalize_llm_provider",
    "parse_uuid",
    "resolve_llm_provider",
]
