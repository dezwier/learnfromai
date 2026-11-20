"""Weighted user–tile affinity (single measure for HUD + cron).

Affinity uses focus + open engagement only (not learn/check/pack walks).
"""

from __future__ import annotations

import math
from collections import defaultdict
from datetime import datetime
from uuid import UUID

from sqlmodel import Session, col, select

from app.core.config import Settings, get_settings
from app.core.time import utcnow
from app.features.knowledge_graph.node_models import KnowledgeNode
from app.features.user_events.models import UserTopicEvent

# Still reported on the profile map for UI; not used in the affinity score.
LEARNED_KINDS = frozenset({"learn", "example", "check1", "check2", "check3"})


def recency(age_days: float, *, half_life_days: float) -> float:
    """Soft half-life decay; never hard-cuts to zero."""
    if half_life_days <= 0:
        return 1.0
    age = max(0.0, float(age_days))
    return math.exp(-math.log(2.0) * age / half_life_days)


def age_days(when: datetime | None, *, now: datetime | None = None) -> float:
    if when is None:
        return 0.0
    current = now or utcnow()
    delta = current - when
    return max(0.0, delta.total_seconds() / 86400.0)


def weights_snapshot(settings: Settings | None = None) -> dict[str, float | int]:
    s = settings or get_settings()
    return {
        "affinity_w_focus": s.affinity_w_focus,
        "affinity_w_open": s.affinity_w_open,
        "affinity_w_new": s.affinity_w_new,
        "affinity_half_life_days": s.affinity_half_life_days,
        "cron_neighbor_w_count_penalty": s.cron_neighbor_w_count_penalty,
        "cron_learn_w_pack_penalty": s.cron_learn_w_pack_penalty,
        "cron_learn_w_neighbor_boost": s.cron_learn_w_neighbor_boost,
        "learn_track_exploit_p": s.learn_track_exploit_p,
        "cron_neighbor_jobs_per_day": s.cron_neighbor_jobs_per_day,
        "cron_learn_jobs_per_day": s.cron_learn_jobs_per_day,
        "cron_neighbor_budget_total": s.cron_neighbor_budget_total,
    }


def score_user_tiles(
    session: Session,
    *,
    user_id: UUID,
    settings: Settings | None = None,
    now: datetime | None = None,
) -> dict[UUID, dict]:
    """Score tiles the user focused/opened. Returns node_id → row dict."""
    s = settings or get_settings()
    current = now or utcnow()
    events = list(
        session.exec(select(UserTopicEvent).where(UserTopicEvent.user_id == user_id)).all()
    )
    if not events:
        return {}

    focus_counts: dict[UUID, int] = defaultdict(int)
    open_counts: dict[UUID, int] = defaultdict(int)
    learned_nodes: set[UUID] = set()
    last_engage_at: dict[UUID, datetime] = {}
    engaged_ids: set[UUID] = set()

    for event in events:
        if event.kind in LEARNED_KINDS:
            learned_nodes.add(event.node_id)
        if event.kind not in ("focus", "open"):
            continue
        engaged_ids.add(event.node_id)
        occurred = event.occurred_at or event.created_at
        prev = last_engage_at.get(event.node_id)
        if prev is None or occurred > prev:
            last_engage_at[event.node_id] = occurred
        if event.kind == "focus":
            focus_counts[event.node_id] += 1
        else:
            open_counts[event.node_id] += 1

    if not engaged_ids:
        return {}

    nodes = session.exec(
        select(KnowledgeNode).where(col(KnowledgeNode.id).in_(list(engaged_ids)))
    ).all()
    by_id = {node.id: node for node in nodes}

    scored: dict[UUID, dict] = {}
    for nid in engaged_ids:
        node = by_id.get(nid)
        if node is None:
            continue
        focus_n = focus_counts.get(nid, 0)
        open_n = open_counts.get(nid, 0)
        node_age = age_days(node.created_at, now=current)
        event_age = age_days(last_engage_at.get(nid), now=current)
        base = (
            s.affinity_w_focus * focus_n
            + s.affinity_w_open * open_n
            + s.affinity_w_new
            * recency(node_age, half_life_days=s.affinity_half_life_days)
        )
        affinity = base * recency(event_age, half_life_days=s.affinity_half_life_days)
        if affinity <= 0:
            continue
        scored[nid] = {
            "id": nid,
            "name": node.name,
            "affinity": float(affinity),
            "focus_count": focus_n,
            "open_count": open_n,
            "learned": nid in learned_nodes,
            "has_image": bool(node.image_url),
        }
    return scored


def aggregate_tile_affinity(
    session: Session,
    *,
    settings: Settings | None = None,
    now: datetime | None = None,
) -> dict[UUID, dict]:
    """Sum user–tile affinity across all users.

    Returns node_id → {affinity, name, top_user_id} where top_user_id is the
    user with the highest affinity on that tile (for cron job attribution).
    """
    s = settings or get_settings()
    current = now or utcnow()
    user_ids = list(session.exec(select(UserTopicEvent.user_id).distinct()).all())
    totals: dict[UUID, float] = defaultdict(float)
    names: dict[UUID, str] = {}
    top_user: dict[UUID, tuple[float, UUID]] = {}
    for uid in user_ids:
        if uid is None:
            continue
        for nid, row in score_user_tiles(
            session, user_id=uid, settings=s, now=current
        ).items():
            score = float(row["affinity"])
            totals[nid] += score
            names[nid] = row["name"]
            prev = top_user.get(nid)
            if prev is None or score > prev[0]:
                top_user[nid] = (score, uid)
    return {
        nid: {
            "id": nid,
            "name": names[nid],
            "affinity": score,
            "top_user_id": top_user[nid][1],
        }
        for nid, score in totals.items()
        if score > 0
    }
