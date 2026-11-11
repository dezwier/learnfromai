"""Per-user neighborhood size settings."""

from __future__ import annotations

from typing import Any

from app.features.accounts.models import User

DEFAULTS = {
    "parents": 2,
    "siblings": 3,
    "children": 4,
    "acquaintances": 4,
    "extended": 12,
}

CLAMPS = {
    "parents": (1, 2),
    "siblings": (2, 3),
    "children": (3, 5),
    "acquaintances": (3, 5),
    "extended": (0, 24),
}


def neighborhood_counts(user: User | None = None, raw: dict | None = None) -> dict[str, int]:
    prefs = raw if raw is not None else ((user.preferences if user is not None else None) or {})
    block = prefs.get("neighborhood") if isinstance(prefs, dict) else None
    source = block if isinstance(block, dict) else {}
    return {key: _clamp(key, source.get(key, DEFAULTS[key])) for key in DEFAULTS}


def merge_neighborhood_prefs(preferences: dict | None, updates: dict[str, Any]) -> dict:
    current = dict(preferences or {})
    block = dict(current.get("neighborhood") or {}) if isinstance(current.get("neighborhood"), dict) else {}
    for key in DEFAULTS:
        if key in updates and updates[key] is not None:
            block[key] = _clamp(key, updates[key])
    current["neighborhood"] = block
    return current


def _clamp(key: str, value: object) -> int:
    low, high = CLAMPS[key]
    try:
        number = int(value)  # type: ignore[arg-type]
    except (TypeError, ValueError):
        number = DEFAULTS[key]
    return max(low, min(high, number))
