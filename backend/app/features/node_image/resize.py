"""Derive phone-friendly full + hex thumb sizes from one generated image."""

from __future__ import annotations

import io

from PIL import Image

# Topic-screen / retina detail. Model output is typically already ~1024.
FULL_MAX_EDGE = 1024
# Graph hex tiles: neighbor ~120–180 CSS px @3x; focus flower a bit larger.
THUMB_EDGE = 512
THUMB_JPEG_QUALITY = 82


def prepare_node_images(raw: bytes) -> tuple[bytes, bytes]:
    """Return (full_png_bytes, thumb_jpeg_bytes) from one model PNG/JPEG."""
    with Image.open(io.BytesIO(raw)) as image:
        rgb = image.convert("RGB")
        full = _fit_square(rgb, FULL_MAX_EDGE)
        thumb = _fit_square(rgb, THUMB_EDGE)
    full_buf = io.BytesIO()
    full.save(full_buf, format="PNG", optimize=True)
    thumb_buf = io.BytesIO()
    thumb.save(thumb_buf, format="JPEG", quality=THUMB_JPEG_QUALITY, optimize=True)
    return full_buf.getvalue(), thumb_buf.getvalue()


def _fit_square(image: Image.Image, edge: int) -> Image.Image:
    """Center-crop to square, then scale so the edge matches [edge] (never upscale)."""
    width, height = image.size
    side = min(width, height)
    left = (width - side) // 2
    top = (height - side) // 2
    cropped = image.crop((left, top, left + side, top + side))
    if side <= edge:
        return cropped
    return cropped.resize((edge, edge), Image.Resampling.LANCZOS)
