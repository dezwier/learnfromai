"""Global neighborhood size and per-user LLM provider settings."""

from __future__ import annotations

from typing import Any

from app.features.accounts.models import User
from app.features.platform.neighborhood_llm import normalize_llm_provider

# Shared expand / canvas budget (not per-user).
# Expand aims for `total` direct neighbors; the canvas shows at most
# `canvas_max` tiles (focus + directs + extended), filling extended after directs.
DEFAULTS = {
    "total": 16,
    "extended": 14,
    "canvas_max": 30,
}

DEFAULT_LLM_PROVIDER = "openai"
ALLOWED_LLM_PROVIDERS = frozenset({"gemini", "openai"})


def neighborhood_counts(user: User | None = None, raw: dict | None = None) -> dict[str, int]:
    """Global neighborhood sizes. `user` / `raw` ignored (API compat)."""
    del user, raw
    total = DEFAULTS["total"]
    return {
        "total": total,
        "extended": DEFAULTS["extended"],
        "canvas_max": DEFAULTS["canvas_max"],
        "min_per_bucket": min_per_bucket(total),
    }


def min_per_bucket(total: int) -> int:
    """At least one of each when possible; two when the budget is comfortable."""
    if total < 4:
        return 1
    return 2 if total >= 12 else 1


def merge_neighborhood_prefs(preferences: dict | None, updates: dict[str, Any] | None = None) -> dict:
    """Drop any stored personal neighborhood sizes (sizes are global only)."""
    del updates
    current = dict(preferences or {})
    current.pop("neighborhood", None)
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
