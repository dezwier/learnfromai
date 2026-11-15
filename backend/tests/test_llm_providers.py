"""LLM provider factory, OpenAI usage pricing, and sink billing."""

from __future__ import annotations

from sqlmodel import Session, select

from app.core.config import get_settings
from app.features.platform.content_llm import (
    FakeContentLLM,
    GeminiContentLLM,
    OpenAIContentLLM,
    get_content_llm,
)
from app.features.platform.llm import bind_usage_sink, maybe_record_usage
from app.features.platform.llm_usage_pricing import usage_from_openai_usage
from app.features.platform.models import LlmUsage
from app.features.platform.neighborhood_llm import (
    FakeNeighborhoodLLM,
    GeminiNeighborhoodLLM,
    OpenAINeighborhoodLLM,
    get_neighborhood_llm,
    normalize_llm_provider,
    resolve_llm_provider,
)


def test_normalize_llm_provider_aliases():
    assert normalize_llm_provider("ChatGPT") == "openai"
    assert normalize_llm_provider("gpt") == "openai"
    assert normalize_llm_provider("openai") == "openai"
    assert normalize_llm_provider("Gemini") == "gemini"
    assert normalize_llm_provider("fake") == "fake"
    assert normalize_llm_provider("claude") is None
    assert normalize_llm_provider(None) is None


def test_usage_from_openai_usage_gpt4o_mini():
    usage = usage_from_openai_usage(
        "gpt-4o-mini",
        {"prompt_tokens": 1000, "completion_tokens": 500, "total_tokens": 1500},
    )
    assert usage["input_tokens"] == 1000
    assert usage["output_tokens"] == 500
    assert usage["source"] == "openai_usage"
    # 1000 * 0.15/1M + 500 * 0.60/1M = 0.00015 + 0.0003 = 0.00045
    assert abs(usage["estimated_cost_usd"] - 0.00045) < 1e-9


def test_factory_branches_by_provider(monkeypatch):
    monkeypatch.setenv("ENVIRONMENT", "development")
    monkeypatch.setenv("LLM_PROVIDER", "gemini")
    get_settings.cache_clear()

    assert isinstance(get_neighborhood_llm("fake"), FakeNeighborhoodLLM)
    assert isinstance(get_content_llm("fake"), FakeContentLLM)
    assert isinstance(get_neighborhood_llm("gemini"), GeminiNeighborhoodLLM)
    assert isinstance(get_content_llm("gemini"), GeminiContentLLM)
    assert isinstance(get_neighborhood_llm("openai"), OpenAINeighborhoodLLM)
    assert isinstance(get_content_llm("chatgpt"), OpenAIContentLLM)
    assert isinstance(get_neighborhood_llm("gpt"), OpenAINeighborhoodLLM)

    monkeypatch.setenv("LLM_PROVIDER", "openai")
    get_settings.cache_clear()
    assert resolve_llm_provider(None) == "openai"
    assert isinstance(get_neighborhood_llm(), OpenAINeighborhoodLLM)

    monkeypatch.setenv("ENVIRONMENT", "test")
    get_settings.cache_clear()
    assert isinstance(get_neighborhood_llm("openai"), FakeNeighborhoodLLM)

    get_settings.cache_clear()


def test_openai_bill_on_parse_failure_via_sink(session: Session, user):
    class BoomLLM:
        name = "openai"

        def __init__(self):
            self.on_usage = None

        def _bill(self, usage_payload):
            usage = usage_from_openai_usage("gpt-4o-mini", usage_payload)
            if callable(self.on_usage):
                self.on_usage(usage)
            return usage

    llm = BoomLLM()
    bind_usage_sink(llm, session, user_id=user.id, job_id=None, task="neighborhood")
    llm._bill({"prompt_tokens": 200, "completion_tokens": 50})
    session.commit()
    rows = list(session.exec(select(LlmUsage)).all())
    assert len(rows) == 1
    assert rows[0].provider == "openai"
    assert rows[0].input_tokens == 200
    assert rows[0].output_tokens == 50
    assert rows[0].estimated_cost_usd > 0


def test_maybe_record_usage_skips_live_provider_with_sink(session: Session, user):
    class Live:
        name = "openai"
        on_usage = lambda usage: None  # noqa: E731

    maybe_record_usage(
        session,
        Live(),
        user_id=user.id,
        job_id=None,
        task="content",
        usage={
            "model": "gpt-4o-mini",
            "input_tokens": 10,
            "output_tokens": 5,
            "estimated_cost_usd": 0.01,
        },
    )
    session.commit()
    assert list(session.exec(select(LlmUsage)).all()) == []
