"""Topic image and profile photo uploads."""

from io import BytesIO

from PIL import Image

from app.features.accounts.models import User
from app.features.knowledge_graph.node_models import KnowledgeNode


def _png_bytes(size: int = 64) -> bytes:
    buf = BytesIO()
    Image.new("RGB", (size, size), color=(40, 120, 200)).save(buf, format="PNG")
    return buf.getvalue()


def test_upload_node_image_stores_full_and_thumb(client, auth, session):
    node = KnowledgeNode(name="Attention", name_key="attention", description="Weighting.")
    session.add(node)
    session.commit()

    response = client.put(
        f"/api/v1/knowledge/nodes/{node.id}/image",
        headers=auth,
        files={"file": ("topic.png", _png_bytes(800), "image/png")},
    )
    assert response.status_code == 200
    body = response.json()
    assert body["incomplete"] is False
    assert body["image_url"] == f"/knowledge/nodes/{node.id}/image/file"

    session.refresh(node)
    assert node.image_bytes is not None
    assert node.image_thumb_bytes is not None

    file_resp = client.get(f"/api/v1/knowledge/nodes/{node.id}/image/file", headers=auth)
    assert file_resp.status_code == 200
    assert file_resp.content[:8] == b"\x89PNG\r\n\x1a\n"


def test_upload_node_image_rejects_non_image(client, auth, session):
    node = KnowledgeNode(name="Softmax", name_key="softmax", description="Normalize.")
    session.add(node)
    session.commit()

    response = client.put(
        f"/api/v1/knowledge/nodes/{node.id}/image",
        headers=auth,
        files={"file": ("notes.txt", b"not an image", "text/plain")},
    )
    assert response.status_code == 422


def test_profile_photo_upload_and_delete(client, auth, session, user: User):
    uploaded = client.put(
        "/api/v1/me/photo",
        headers=auth,
        files={"file": ("avatar.png", _png_bytes(400), "image/png")},
    )
    assert uploaded.status_code == 200
    assert uploaded.json()["photo_url"] == "/me/photo"

    session.refresh(user)
    assert user.photo_bytes is not None
    assert user.photo_bytes[:2] == b"\xff\xd8"

    served = client.get("/api/v1/me/photo", headers=auth)
    assert served.status_code == 200
    assert served.headers["content-type"].startswith("image/jpeg")
    assert served.content == user.photo_bytes

    cleared = client.delete("/api/v1/me/photo", headers=auth)
    assert cleared.status_code == 200
    assert cleared.json()["photo_url"] is None
    session.refresh(user)
    assert user.photo_bytes is None

    missing = client.get("/api/v1/me/photo", headers=auth)
    assert missing.status_code == 404
