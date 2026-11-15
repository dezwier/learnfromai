"""Daily euro spend cap from Gemini usageMetadata."""

from __future__ import annotations

import pytest
from sqlmodel import Session, select

from app.core.config import get_settings
from app.core.errors import AppError
from app.features.platform.gemini_usage import usage_from_gemini_metadata
from app.features.platform.llm import assert_daily_spend, bind_usage_sink, record_usage, spend_eur_today
from app.features.platform.models import LlmUsage


def test_usage_includes_thoughts_as_output():
    usage = usage_from_gemini_metadata(
        "gemini-2.5-flash-lite",
        {
            "promptTokenCount": 1000,
            "candidatesTokenCount": 100,
            "thoughtsTokenCount": 900,
        },
    )
    assert usage["input_tokens"] == 1000
    assert usage["output_tokens"] == 1000  # candidates + thoughts
    assert usage["thoughts_tokens"] == 900
    assert usage["source"] == "gemini_usage_metadata"
    # 1000 * 0.10/1M + 1000 * 0.40/1M = 0.0005
    assert abs(usage["estimated_cost_usd"] - 0.0005) < 1e-9


def test_daily_spend_cap_blocks(session: Session, user, monkeypatch):
    monkeypatch.setenv("LLM_DAILY_SPEND_EUR_LIMIT", "3")
    monkeypatch.setenv("LLM_USD_PER_EUR", "1.0")
    get_settings.cache_clear()

    record_usage(
        session,
        user_id=user.id,
        job_id=None,
        task="neighborhood",
        provider="gemini",
        usage={
            "model": "gemini-2.5-flash-lite",
            "input_tokens": 0,
            "output_tokens": 0,
            "estimated_cost_usd": 2.95,
        },
    )
    session.commit()
    assert spend_eur_today(session) == pytest.approx(2.95)

    assert_daily_spend(session, reserve_usd=0.01)

    with pytest.raises(AppError) as exc:
        assert_daily_spend(session, reserve_usd=0.10)
    assert exc.value.code == "RATE_LIMITED"
    assert "€3" in exc.value.message

    get_settings.cache_clear()


def test_bill_on_parse_failure_via_sink(session: Session, user):
    class BoomLLM:
        name = "gemini"

        def __init__(self):
            self.on_usage = None

        def _bill(self, meta):
            usage = usage_from_gemini_metadata("gemini-2.5-flash-lite", meta)
            if callable(self.on_usage):
                self.on_usage(usage)
            return usage

    llm = BoomLLM()
    bind_usage_sink(llm, session, user_id=user.id, job_id=None, task="neighborhood")
    llm._bill(
        {
            "promptTokenCount": 500,
            "candidatesTokenCount": 50,
            "thoughtsTokenCount": 450,
        }
    )
    session.commit()
    rows = list(session.exec(select(LlmUsage)).all())
    assert len(rows) == 1
    assert rows[0].output_tokens == 500
    assert rows[0].estimated_cost_usd > 0
