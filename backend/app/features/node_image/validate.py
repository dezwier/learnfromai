"""Shared validation for uploaded image bytes."""

from __future__ import annotations

import io

from PIL import Image, UnidentifiedImageError

from app.core.errors import AppError

ALLOWED_CONTENT_TYPES = frozenset(
    {
        "image/jpeg",
        "image/jpg",
        "image/png",
        "image/webp",
        "image/gif",
    }
)


def read_image_upload(
    raw: bytes,
    *,
    content_type: str | None = None,
    max_bytes: int,
) -> bytes:
    """Validate size/type and that Pillow can decode the payload. Returns original bytes."""
    if not raw:
        raise AppError("VALIDATION_ERROR", "Image file is empty", 422)
    if len(raw) > max_bytes:
        raise AppError(
            "VALIDATION_ERROR",
            f"Image must be at most {max_bytes // (1024 * 1024)} MB",
            422,
        )
    if content_type:
        mime = content_type.split(";", 1)[0].strip().lower()
        # Multipart clients sometimes send octet-stream; Pillow still verifies.
        if mime and mime not in ALLOWED_CONTENT_TYPES and mime != "application/octet-stream":
            raise AppError(
                "VALIDATION_ERROR",
                "Image must be JPEG, PNG, WebP, or GIF",
                422,
            )
    try:
        with Image.open(io.BytesIO(raw)) as image:
            image.verify()
    except UnidentifiedImageError as exc:
        raise AppError("VALIDATION_ERROR", "File is not a valid image", 422) from exc
    except OSError as exc:
        raise AppError("VALIDATION_ERROR", "File is not a valid image", 422) from exc
    return raw
