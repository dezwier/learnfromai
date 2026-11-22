"""Pack-level learning-card images."""

import io

from PIL import Image
from sqlmodel import func, select

from app.features.content.models import KnowledgeBit
from app.features.knowledge_graph.node_models import KnowledgeNode
from app.features.node_image.pack_models import KnowledgePackImage
from app.features.platform.image_llm import build_pack_image_prompt, get_image_llm
from app.features.platform.jobs import claim_next
from app.features.platform.models import GenerationJob
from app.workers.handlers import handle


def _valid_png() -> bytes:
    buf = io.BytesIO()
    Image.new("RGB", (8, 8), color=(20, 40, 60)).save(buf, format="PNG")
    return buf.getvalue()


def _run_queued(session):
    claimed = claim_next(session)
    assert claimed is not None
    job, token = claimed
    handle(job.id, token)
    session.expire_all()
    return session.get(GenerationJob, job.id)


def _add_pack(session, node_id, *, pack_index: int = 1):
    session.add(
        KnowledgeBit(
            node_id=node_id,
            pack_index=pack_index,
            kind="learn",
            body={"title": "Softmax tip", "markdown": "Softmax turns logits into probabilities."},
        )
    )
    session.add(
        KnowledgeBit(
            node_id=node_id,
            pack_index=pack_index,
            kind="check1",
            body={
                "type": "mc",
                "question": "What does Softmax do?",
                "choices": ["Normalize", "Add", "Multiply", "Ignore"],
                "answer_index": 0,
                "explanation": "It normalizes.",
            },
        )
    )
    session.commit()


def test_pack_image_prompt_includes_learn_bit():
    prompt = build_pack_image_prompt(
        "Softmax",
        "Normalize scores",
        learn_title="Softmax tip",
        learn_markdown="Softmax turns logits into probabilities.",
    )
    assert "atomic learning" in prompt
    assert "Softmax tip" in prompt
    assert "logits into probabilities" in prompt
    assert "photorealistic" in prompt
    assert "TEXT-FREE" in prompt
    assert "zero writing" in prompt
    assert "never print it" in prompt
    assert "conceptual guidance only" in prompt


def test_pack_image_generate_and_learning_next_fallback(client, auth, session):
    node = KnowledgeNode(
        name="Softmax",
        name_key="softmax-pack-img",
        description="Normalize scores.",
        image_url="/knowledge/nodes/placeholder/image/file",
        image_bytes=_valid_png(),
    )
    session.add(node)
    session.commit()
    _add_pack(session, node.id)

    # Without pack image, learning-next uses topic image.
    next_before = client.get(
        f"/api/v1/me/learning-next?seed_node_id={node.id}&opening=true",
        headers=auth,
    )
    assert next_before.status_code == 200
    body = next_before.json()
    assert body["status"] == "ready"
    assert body["image_url"] == f"/knowledge/nodes/{node.id}/image/file"
    assert body["pack_image_url"] is None

    queued = client.post(
        f"/api/v1/knowledge/nodes/{node.id}/packs/1/image",
        headers=auth,
        json={"generate": True},
    )
    assert queued.status_code == 202
    assert queued.json()["job_id"]
    assert queued.json()["pack_index"] == 1

    job = _run_queued(session)
    assert job is not None
    assert job.state == "succeeded"
    assert job.result["pack_index"] == 1
    assert job.result["image_url"] == f"/knowledge/nodes/{node.id}/packs/1/image/file"

    meta = client.get(
        f"/api/v1/knowledge/nodes/{node.id}/packs/1/image",
        headers=auth,
    )
    assert meta.status_code == 200
    assert meta.json()["incomplete"] is False

    file_resp = client.get(
        f"/api/v1/knowledge/nodes/{node.id}/packs/1/image/file",
        headers=auth,
    )
    assert file_resp.status_code == 200
    assert file_resp.headers["content-type"].startswith("image/png")

    next_after = client.get(
        f"/api/v1/me/learning-next?seed_node_id={node.id}&opening=true",
        headers=auth,
    )
    assert next_after.status_code == 200
    after = next_after.json()
    assert after["image_url"] == f"/knowledge/nodes/{node.id}/packs/1/image/file"
    assert after["pack_image_url"] == f"/knowledge/nodes/{node.id}/packs/1/image/file"

    content = client.get(f"/api/v1/knowledge/nodes/{node.id}/content", headers=auth)
    pack = content.json()["packs"][0]
    assert pack["pack_image_url"] == f"/knowledge/nodes/{node.id}/packs/1/image/file"
    assert pack["image_url"] == pack["pack_image_url"]


def test_pack_image_upload_and_admin_delete_cleans_image(client, auth, session, user):
    user.is_admin = True
    session.add(user)
    node = KnowledgeNode(name="Attention", name_key="attention-pack-img", description="Weights.")
    session.add(node)
    session.commit()
    _add_pack(session, node.id)

    uploaded = client.put(
        f"/api/v1/knowledge/nodes/{node.id}/packs/1/image",
        headers=auth,
        files={"file": ("pack.png", _valid_png(), "image/png")},
    )
    assert uploaded.status_code == 200
    assert uploaded.json()["incomplete"] is False
    assert session.exec(select(func.count()).select_from(KnowledgePackImage)).one() == 1

    deleted = client.delete(
        f"/api/v1/admin/knowledge/nodes/{node.id}/packs/1",
        headers=auth,
    )
    assert deleted.status_code == 200
    assert deleted.json()["images_deleted"] == 1
    assert session.exec(select(func.count()).select_from(KnowledgePackImage)).one() == 0


def test_pack_image_skips_when_present_unless_regenerate(client, auth, session):
    node = KnowledgeNode(name="Softmax", name_key="softmax-pack-regen", description="x")
    session.add(node)
    session.commit()
    _add_pack(session, node.id)

    png, _ = get_image_llm("fake").generate_image("Softmax", None)
    session.add(
        KnowledgePackImage(
            node_id=node.id,
            pack_index=1,
            image_url=f"/knowledge/nodes/{node.id}/packs/1/image/file",
            image_bytes=png,
        )
    )
    session.commit()

    again = client.post(
        f"/api/v1/knowledge/nodes/{node.id}/packs/1/image",
        headers=auth,
        json={"generate": True},
    )
    assert again.status_code == 200
    assert again.json().get("job_id") is None

    regen = client.post(
        f"/api/v1/knowledge/nodes/{node.id}/packs/1/image",
        headers=auth,
        json={"regenerate": True},
    )
    assert regen.status_code == 202
    assert regen.json()["job_id"]
