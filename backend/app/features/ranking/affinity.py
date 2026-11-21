"""Weighted user–tile affinity (single measure for HUD + cron).

Per-user normalized factors (each in a bounded range), then weighted sum.

Interest comes only from intentional `open` events (graph / search / list /
settings). Cold-start resume `focus` events do not count.

  interest_norm[t]  = open_count[t] / Σ_tiles open_count
  neighbor_norm[t]  = Σ_direct_neighbors open_count / Σ_tiles open_count
  recency[t]        = linear map of days since last intentional open
                      today → 1.0, ≥ span (default 30d) → 0.5

affinity = w_interest * interest_norm
         + w_neighbor * neighbor_norm
         + w_recency  * recency
"""

from __future__ import annotations

from collections import defaultdict
from datetime import datetime
from uuid import UUID

from sqlalchemy import or_
from sqlmodel import Session, col, select

from app.core.config import Settings, get_settings
from app.core.time import utcnow
from app.features.knowledge_graph.node_models import KnowledgeEdge, KnowledgeNode
from app.features.user_events.models import OPEN_SOURCES, UserTopicEvent

# Still reported on the profile map for UI; not used in the affinity score.
LEARNED_KINDS = frozenset({"learn", "example", "check1", "check2", "check3"})
# Intentional opens only (matches OPEN_SOURCES).
INTEREST_OPEN_SOURCES = frozenset(OPEN_SOURCES)

# Recency floor / ceiling for the linear span.
_RECENCY_FLOOR = 0.5
_RECENCY_CEILING = 1.0


def recency(
    age_days: float,
    *,
    span_days: float,
    floor: float = _RECENCY_FLOOR,
    ceiling: float = _RECENCY_CEILING,
) -> float:
    """Linear recency: today → ceiling, age ≥ span → floor."""
    if span_days <= 0:
        return ceiling
    age = max(0.0, float(age_days))
    if age >= span_days:
        return floor
    t = age / span_days
    return ceiling + (floor - ceiling) * t


def age_days(when: datetime | None, *, now: datetime | None = None) -> float:
    if when is None:
        return 0.0
    current = now or utcnow()
    delta = current - when
    return max(0.0, delta.total_seconds() / 86400.0)


def weights_snapshot(settings: Settings | None = None) -> dict[str, float | int]:
    s = settings or get_settings()
    return {
        "affinity_w_interest": s.affinity_w_interest,
        "affinity_w_neighbor": s.affinity_w_neighbor,
        "affinity_w_recency": s.affinity_w_recency,
        "affinity_recency_span_days": s.affinity_recency_span_days,
        "cron_neighbor_w_fill": s.cron_neighbor_w_fill,
        "cron_neighbor_budget_total": s.cron_neighbor_budget_total,
        "cron_learn_w_fill": s.cron_learn_w_fill,
        "cron_learn_desired_packs": s.cron_learn_desired_packs,
        "learn_track_exploit_p": s.learn_track_exploit_p,
        "cron_neighbor_jobs_per_day": s.cron_neighbor_jobs_per_day,
        "cron_learn_jobs_per_day": s.cron_learn_jobs_per_day,
    }


def _undirected_neighbors(
    session: Session, node_ids: set[UUID]
) -> dict[UUID, set[UUID]]:
    """Map each node → direct neighbors (either edge direction)."""
    if not node_ids:
        return {}
    ids = list(node_ids)
    edges = session.exec(
        select(KnowledgeEdge).where(
            or_(
                col(KnowledgeEdge.from_id).in_(ids),
                col(KnowledgeEdge.to_id).in_(ids),
            )
        )
    ).all()
    neighbors: dict[UUID, set[UUID]] = defaultdict(set)
    for edge in edges:
        neighbors[edge.from_id].add(edge.to_id)
        neighbors[edge.to_id].add(edge.from_id)
    return neighbors


def score_user_tiles(
    session: Session,
    *,
    user_id: UUID,
    settings: Settings | None = None,
    now: datetime | None = None,
) -> dict[UUID, dict]:
    """Score tiles from intentional opens. Returns node_id → row dict."""
    s = settings or get_settings()
    current = now or utcnow()
    events = list(
        session.exec(select(UserTopicEvent).where(UserTopicEvent.user_id == user_id)).all()
    )
    if not events:
        return {}

    focus_counts: dict[UUID, int] = defaultdict(int)
    open_counts: dict[UUID, int] = defaultdict(int)
    interest_by_id: dict[UUID, float] = defaultdict(float)
    learned_nodes: set[UUID] = set()
    last_engage_at: dict[UUID, datetime] = {}
    engaged_ids: set[UUID] = set()

    for event in events:
        if event.kind in LEARNED_KINDS:
            learned_nodes.add(event.node_id)
        if event.kind == "focus":
            # Reported for UI; not used in interest (includes cold-start resume).
            focus_counts[event.node_id] += 1
            continue
        if event.kind != "open":
            continue
        payload = event.payload if isinstance(event.payload, dict) else {}
        source = str(payload.get("source") or "").strip()
        if source not in INTEREST_OPEN_SOURCES:
            continue
        engaged_ids.add(event.node_id)
        occurred = event.occurred_at or event.created_at
        prev = last_engage_at.get(event.node_id)
        if prev is None or occurred > prev:
            last_engage_at[event.node_id] = occurred
        open_counts[event.node_id] += 1

    if not engaged_ids:
        return {}

    for nid in engaged_ids:
        interest_by_id[nid] = float(open_counts.get(nid, 0))

    total_interest = sum(interest_by_id.values())
    if total_interest <= 0:
        return {}

    nodes = session.exec(
        select(KnowledgeNode).where(col(KnowledgeNode.id).in_(list(engaged_ids)))
    ).all()
    by_id = {node.id: node for node in nodes}
    neighbor_map = _undirected_neighbors(session, engaged_ids)

    scored: dict[UUID, dict] = {}
    for nid in engaged_ids:
        node = by_id.get(nid)
        if node is None:
            continue
        focus_n = focus_counts.get(nid, 0)
        open_n = open_counts.get(nid, 0)
        interest_raw = interest_by_id[nid]
        neighbor_raw = 0.0
        for nb in neighbor_map.get(nid, ()):
            neighbor_raw += interest_by_id.get(nb, 0.0)
        interest_norm = interest_raw / total_interest
        neighbor_norm = neighbor_raw / total_interest
        event_age = age_days(last_engage_at.get(nid), now=current)
        recency_norm = float(
            recency(event_age, span_days=s.affinity_recency_span_days)
        )
        interest_term = float(s.affinity_w_interest * interest_norm)
        neighbor_term = float(s.affinity_w_neighbor * neighbor_norm)
        recency_term = float(s.affinity_w_recency * recency_norm)
        affinity = interest_term + neighbor_term + recency_term
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
            "breakdown": {
                "interest": round(interest_term, 6),
                "neighbor": round(neighbor_term, 6),
                "recency": round(recency_term, 6),
            },
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
