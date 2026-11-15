"""LLM usage accounting and hard daily spend / token quotas."""

from __future__ import annotations

from uuid import UUID

from sqlmodel import Session, func, select

from app.core.config import get_settings
from app.core.time import utcnow
from app.features.platform.models import LlmUsage


def record_usage(
    session: Session,
    *,
    user_id: UUID | None,
    job_id: UUID | None,
    task: str,
    provider: str,
    usage: dict,
) -> None:
    session.add(
        LlmUsage(
            user_id=user_id,
            job_id=job_id,
            task=task,
            provider=provider,
            model=str(usage.get("model") or provider),
            input_tokens=int(usage.get("input_tokens") or 0),
            output_tokens=int(usage.get("output_tokens") or 0),
            estimated_cost_usd=float(usage.get("estimated_cost_usd") or 0),
        )
    )


def tokens_used_today(session: Session, user_id: UUID) -> int:
    start = _day_start()
    total = session.exec(
        select(func.coalesce(func.sum(LlmUsage.input_tokens + LlmUsage.output_tokens), 0)).where(
            LlmUsage.user_id == user_id,
            LlmUsage.created_at >= start,
        )
    ).one()
    return int(total)


def spend_usd_today(session: Session) -> float:
    """Global (all users) USD spend today from recorded LLM usage."""
    start = _day_start()
    total = session.exec(
        select(func.coalesce(func.sum(LlmUsage.estimated_cost_usd), 0.0)).where(
            LlmUsage.created_at >= start,
        )
    ).one()
    return float(total or 0.0)


def spend_eur_today(session: Session) -> float:
    settings = get_settings()
    return spend_usd_today(session) / max(settings.llm_usd_per_eur, 0.01)


def daily_spend_usd_limit() -> float:
    settings = get_settings()
    return float(settings.llm_daily_spend_eur_limit) * float(settings.llm_usd_per_eur)


def assert_user_quota(session: Session, user_id: UUID) -> None:
    """Per-user token cap + global daily euro spend cap (terminal)."""
    from app.core.errors import rate_limited

    settings = get_settings()
    if tokens_used_today(session, user_id) >= settings.llm_daily_tokens_user_limit:
        raise rate_limited("Daily token quota exceeded")
    assert_daily_spend(session)


def assert_daily_spend(session: Session, *, reserve_usd: float = 0.0) -> None:
    """Hard stop when recorded LLM-billed spend for today hits the euro cap."""
    from app.core.errors import rate_limited

    limit_usd = daily_spend_usd_limit()
    spent = spend_usd_today(session)
    if spent + max(0.0, float(reserve_usd)) >= limit_usd:
        eur = get_settings().llm_daily_spend_eur_limit
        raise rate_limited(
            f"Daily LLM spend limit reached (€{eur:g}). Try again tomorrow."
        )


def bind_usage_sink(
    llm: object,
    session: Session,
    *,
    user_id: UUID | None,
    job_id: UUID | None,
    task: str,
) -> None:
    """Record every provider HTTP response (incl. failed JSON) and re-check the cap."""

    setattr(llm, "usage_task", task)

    def _sink(usage: dict) -> None:
        record_usage(
            session,
            user_id=user_id,
            job_id=job_id,
            task=str(getattr(llm, "usage_task", task) or task),
            provider=getattr(llm, "name", "gemini"),
            usage=usage,
        )
        session.flush()
        assert_daily_spend(session)

    def _before(reserve_usd: float) -> None:
        assert_daily_spend(session, reserve_usd=float(reserve_usd or 0))

    setattr(llm, "on_usage", _sink)
    setattr(llm, "before_call", _before)


def maybe_record_usage(
    session: Session,
    llm: object,
    *,
    user_id: UUID | None,
    job_id: UUID | None,
    task: str,
    usage: dict,
) -> None:
    """Record returned usage for fake LLMs; live providers already billed via on_usage."""
    if callable(getattr(llm, "on_usage", None)) and getattr(llm, "name", None) != "fake":
        assert_daily_spend(session)
        return
    record_usage(session, user_id=user_id, job_id=job_id, task=task, provider=getattr(llm, "name", "fake"), usage=usage)


def _day_start():
    return utcnow().replace(hour=0, minute=0, second=0, microsecond=0)
