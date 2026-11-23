"""Env Settings plus optional DB overrides for cron fill weights."""

from __future__ import annotations

from sqlmodel import Session

from app.core.config import Settings, get_settings
from app.core.time import utcnow
from app.features.ranking.models import RankingConfig

_SINGLETON_ID = 1


def effective_ranking_settings(
    session: Session, *, settings: Settings | None = None
) -> Settings:
    """Env defaults, overridden by admin-saved fill weights when present."""
    base = settings or get_settings()
    row = session.get(RankingConfig, _SINGLETON_ID)
    if row is None:
        return base
    updates: dict[str, float] = {}
    if row.neighbor_w_fill is not None:
        updates["cron_neighbor_w_fill"] = float(row.neighbor_w_fill)
    if row.learn_w_fill is not None:
        updates["cron_learn_w_fill"] = float(row.learn_w_fill)
    return base.model_copy(update=updates) if updates else base


def update_fill_weights(
    session: Session,
    *,
    neighbor_w_fill: float | None = None,
    learn_w_fill: float | None = None,
) -> RankingConfig:
    """Upsert singleton fill weights. ``None`` leaves that field unchanged."""
    row = session.get(RankingConfig, _SINGLETON_ID)
    if row is None:
        base = get_settings()
        row = RankingConfig(
            id=_SINGLETON_ID,
            neighbor_w_fill=float(base.cron_neighbor_w_fill),
            learn_w_fill=float(base.cron_learn_w_fill),
        )
        session.add(row)
        session.flush()
    if neighbor_w_fill is not None:
        row.neighbor_w_fill = float(neighbor_w_fill)
    if learn_w_fill is not None:
        row.learn_w_fill = float(learn_w_fill)
    row.updated_at = utcnow()
    session.add(row)
    session.flush()
    return row
