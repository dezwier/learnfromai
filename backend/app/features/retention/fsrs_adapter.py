"""Pinned FSRS 6.3.2 adapter. Schedules review items, not concepts."""

from __future__ import annotations

from datetime import datetime, timezone

from fsrs import Card, Rating, Scheduler

SCHEDULER_VERSION = "fsrs-6.3.2"
_SCHEDULER = Scheduler()


def new_card_state(now: datetime) -> dict:
    card = Card(due=now)
    data = card.to_dict()
    data["scheduler_version"] = SCHEDULER_VERSION
    return data


def review_state(state: dict, rating_name: str, now: datetime) -> tuple[dict, dict]:
    card = Card.from_dict({key: value for key, value in state.items() if key != "scheduler_version"})
    rating = _rating(rating_name)
    updated, log = _SCHEDULER.review_card(card, rating, review_datetime=_aware(now))
    after = updated.to_dict()
    after["scheduler_version"] = SCHEDULER_VERSION
    event = log.to_dict()
    event["rating_name"] = rating_name
    event["scheduler_version"] = SCHEDULER_VERSION
    return after, event


def due_from_state(state: dict) -> datetime:
    raw = state.get("due")
    if isinstance(raw, datetime):
        return _aware(raw)
    parsed = datetime.fromisoformat(str(raw))
    return _aware(parsed)


def rating_from_score(score: float, override: str | None = None) -> str:
    if override in {"again", "hard", "good", "easy"}:
        return override
    if score < 0.4:
        return "again"
    if score < 0.7:
        return "hard"
    if score < 0.9:
        return "good"
    return "easy"


def _rating(name: str) -> Rating:
    return {"again": Rating.Again, "hard": Rating.Hard, "good": Rating.Good, "easy": Rating.Easy}[name]


def _aware(value: datetime) -> datetime:
    if value.tzinfo is None:
        return value.replace(tzinfo=timezone.utc)
    return value.astimezone(timezone.utc)
