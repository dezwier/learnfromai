"""LLM usage accounting and per-user daily token quotas."""

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
    start = utcnow().replace(hour=0, minute=0, second=0, microsecond=0)
    total = session.exec(
        select(func.coalesce(func.sum(LlmUsage.input_tokens + LlmUsage.output_tokens), 0)).where(
            LlmUsage.user_id == user_id,
            LlmUsage.created_at >= start,
        )
    ).one()
    return int(total)


def assert_user_quota(session: Session, user_id: UUID) -> None:
    from app.core.errors import rate_limited

    if tokens_used_today(session, user_id) >= get_settings().llm_daily_tokens_user_limit:
        raise rate_limited()
