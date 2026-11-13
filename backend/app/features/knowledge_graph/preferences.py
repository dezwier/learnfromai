"""Per-user neighborhood size settings."""

from __future__ import annotations

from typing import Any

from app.features.accounts.models import User

DEFAULTS = {
    "total": 16,
    "extended": 12,
}

CLAMPS = {
    "total": (8, 32),
    "extended": (0, 24),
}

_LEGACY_BUCKETS = ("parents", "siblings", "children", "acquaintances")


def neighborhood_counts(user: User | None = None, raw: dict | None = None) -> dict[str, int]:
    prefs = raw if raw is not None else ((user.preferences if user is not None else None) or {})
    block = prefs.get("neighborhood") if isinstance(prefs, dict) else None
    source = block if isinstance(block, dict) else {}
    total = source.get("total")
    if total is None and any(key in source for key in _LEGACY_BUCKETS):
        total = sum(_as_int(source.get(key), 0) for key in _LEGACY_BUCKETS) or DEFAULTS["total"]
    total = _clamp("total", total if total is not None else DEFAULTS["total"])
    extended = _clamp("extended", source.get("extended", DEFAULTS["extended"]))
    return {
        "total": total,
        "extended": extended,
        "min_per_bucket": min_per_bucket(total),
    }


def min_per_bucket(total: int) -> int:
    """At least one of each when possible; two when the budget is comfortable."""
    if total < 4:
        return 1
    return 2 if total >= 12 else 1


def merge_neighborhood_prefs(preferences: dict | None, updates: dict[str, Any]) -> dict:
    current = dict(preferences or {})
    block = dict(current.get("neighborhood") or {}) if isinstance(current.get("neighborhood"), dict) else {}
    for key in list(block):
        if key in _LEGACY_BUCKETS:
            block.pop(key, None)
    for key in DEFAULTS:
        if key in updates and updates[key] is not None:
            block[key] = _clamp(key, updates[key])
    current["neighborhood"] = block
    return current


def _as_int(value: object, default: int) -> int:
    try:
        return int(value)  # type: ignore[arg-type]
    except (TypeError, ValueError):
        return default


def _clamp(key: str, value: object) -> int:
    low, high = CLAMPS[key]
    number = _as_int(value, DEFAULTS[key])
    return max(low, min(high, number))
