"""Profile fields stored on the user row and in preferences."""

from __future__ import annotations

from typing import Any

from app.features.accounts.models import User


def profile_fields(user: User) -> dict[str, str | None]:
    prefs = user.preferences if isinstance(user.preferences, dict) else {}
    profile = prefs.get("profile") if isinstance(prefs.get("profile"), dict) else {}
    username = profile.get("username")
    full_name = profile.get("full_name")
    photo_url = profile.get("photo_url")
    return {
        "email": user.email,
        "username": str(username).strip() if username else None,
        "full_name": str(full_name).strip() if full_name else (user.display_name or None),
        "photo_url": str(photo_url).strip() if photo_url else None,
        "display_name": user.display_name
        or (str(full_name).strip() if full_name else None)
        or (str(username).strip() if username else None)
        or user.email
        or "Learner",
    }


def merge_profile_prefs(preferences: dict | None, updates: dict[str, Any]) -> dict:
    current = dict(preferences or {})
    block = dict(current.get("profile") or {}) if isinstance(current.get("profile"), dict) else {}
    for key in ("username", "full_name", "photo_url"):
        if key not in updates:
            continue
        value = updates[key]
        if value is None:
            block.pop(key, None)
            continue
        text = str(value).strip()
        if not text:
            block.pop(key, None)
        else:
            block[key] = text[:200] if key != "photo_url" else text[:2000]
    current["profile"] = block
    return current
