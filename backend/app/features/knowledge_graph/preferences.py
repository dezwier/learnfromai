"""Per-user neighborhood size and LLM provider settings."""

from __future__ import annotations

from typing import Any

from app.features.accounts.models import User
from app.features.platform.neighborhood_llm import normalize_llm_provider

DEFAULTS = {
    "total": 16,
    "extended": 12,
}

DEFAULT_LLM_PROVIDER = "openai"
ALLOWED_LLM_PROVIDERS = frozenset({"gemini", "openai"})

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


def preferred_llm_provider(user: User | None = None, raw: dict | None = None) -> str | None:
    """Raw stored preference for jobs (None → factory uses env default)."""
    prefs = raw if raw is not None else ((user.preferences if user is not None else None) or {})
    if not isinstance(prefs, dict):
        return None
    normalized = normalize_llm_provider(prefs.get("llm_provider"))
    if normalized in ALLOWED_LLM_PROVIDERS:
        return normalized
    return None


def llm_provider_for(user: User | None = None, raw: dict | None = None) -> str:
    """Preference for API/UI (defaults to openai when unset)."""
    return preferred_llm_provider(user, raw) or DEFAULT_LLM_PROVIDER


def merge_llm_provider_pref(preferences: dict | None, value: object | None) -> dict:
    current = dict(preferences or {})
    if value is None:
        return current
    normalized = normalize_llm_provider(value)
    if normalized not in ALLOWED_LLM_PROVIDERS:
        from app.core.errors import AppError

        raise AppError(
            "VALIDATION_ERROR",
            "llm_provider must be gemini or openai",
            422,
        )
    current["llm_provider"] = normalized
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
