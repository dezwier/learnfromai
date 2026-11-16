"""Profile photo upload and serve (Postgres bytes, API path as photo_url)."""

from __future__ import annotations

import io

from PIL import Image
from sqlmodel import Session

from app.core.errors import not_found
from app.features.accounts.models import User
from app.features.accounts.profile import merge_profile_prefs
from app.features.node_image.validate import read_image_upload

PHOTO_PATH = "/me/photo"
MAX_UPLOAD_BYTES = 5 * 1024 * 1024
AVATAR_EDGE = 512
AVATAR_JPEG_QUALITY = 85


def photo_bytes_for(user: User) -> tuple[bytes, str]:
    if user.photo_bytes:
        return bytes(user.photo_bytes), "image/jpeg"
    raise not_found("Profile photo not found")


def store_uploaded_photo(session: Session, user: User, raw: bytes, *, content_type: str | None) -> dict:
    payload = read_image_upload(raw, content_type=content_type, max_bytes=MAX_UPLOAD_BYTES)
    user.photo_bytes = _prepare_avatar(payload)
    user.preferences = merge_profile_prefs(user.preferences, {"photo_url": PHOTO_PATH})
    session.add(user)
    session.flush()
    return {"photo_url": PHOTO_PATH}


def clear_photo(session: Session, user: User) -> dict:
    user.photo_bytes = None
    user.preferences = merge_profile_prefs(user.preferences, {"photo_url": None})
    session.add(user)
    session.flush()
    return {"photo_url": None}


def clear_photo_bytes_if_external_url(user: User, photo_url: str | None) -> None:
    """Clear stored bytes when photo_url is removed or set to a non-API URL."""
    text = str(photo_url).strip() if photo_url is not None else ""
    if not text:
        user.photo_bytes = None
        return
    if text == PHOTO_PATH or text.endswith(PHOTO_PATH):
        return
    user.photo_bytes = None


def _prepare_avatar(raw: bytes) -> bytes:
    with Image.open(io.BytesIO(raw)) as image:
        rgb = image.convert("RGB")
        width, height = rgb.size
        side = min(width, height)
        left = (width - side) // 2
        top = (height - side) // 2
        cropped = rgb.crop((left, top, left + side, top + side))
        if side > AVATAR_EDGE:
            cropped = cropped.resize((AVATAR_EDGE, AVATAR_EDGE), Image.Resampling.LANCZOS)
    buf = io.BytesIO()
    cropped.save(buf, format="JPEG", quality=AVATAR_JPEG_QUALITY, optimize=True)
    return buf.getvalue()
