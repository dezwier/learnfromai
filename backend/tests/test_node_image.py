"""Shared topic image generation jobs."""

from sqlmodel import func, select

from app.features.knowledge_graph.node_models import KnowledgeNode
from app.features.platform.image_llm import build_topic_image_prompt, get_image_llm
from app.features.platform.jobs import claim_next
from app.features.platform.llm_usage_pricing import image_cost_usd
from app.features.platform.models import GenerationJob, LlmUsage
from app.workers.handlers import handle


def _run_queued(session):
    claimed = claim_next(session)
    assert claimed is not None
    job, token = claimed
    handle(job.id, token)
    session.expire_all()
    return session.get(GenerationJob, job.id)


def test_image_get_never_enqueues(client, auth, session):
    node = KnowledgeNode(name="Attention", name_key="attention", description="Weighting context.")
    session.add(node)
    session.commit()

    response = client.get(f"/api/v1/knowledge/nodes/{node.id}/image", headers=auth)
    assert response.status_code == 200
    body = response.json()
    assert body["incomplete"] is True
    assert body["image_url"] is None
    assert session.exec(select(func.count()).select_from(GenerationJob)).one() == 0


def test_image_generate_persists_png_and_usage(client, auth, session):
    node = KnowledgeNode(name="Attention", name_key="attention", description="Weighting context.")
    session.add(node)
    session.commit()

    queued = client.post(
        f"/api/v1/knowledge/nodes/{node.id}/image",
        headers=auth,
        json={"generate": True},
    )
    assert queued.status_code == 202
    assert queued.json()["job_id"]
    assert queued.json()["focus_node_id"] == str(node.id)

    job = _run_queued(session)
    assert job is not None
    assert job.state == "succeeded"
    assert job.result["image_url"] == f"/knowledge/nodes/{node.id}/image/file"

    ready = client.get(f"/api/v1/knowledge/nodes/{node.id}/image", headers=auth)
    assert ready.status_code == 200
    assert ready.json()["incomplete"] is False
    assert ready.json()["image_url"] == f"/knowledge/nodes/{node.id}/image/file"

    file_resp = client.get(f"/api/v1/knowledge/nodes/{node.id}/image/file", headers=auth)
    assert file_resp.status_code == 200
    assert file_resp.headers["content-type"].startswith("image/png")
    assert file_resp.content[:8] == b"\x89PNG\r\n\x1a\n"

    graph = client.get(f"/api/v1/knowledge/graph/{node.id}", headers=auth)
    assert graph.status_code == 200
    focus = next(n for n in graph.json()["nodes"] if n["id"] == str(node.id))
    assert focus["image_url"] == f"/knowledge/nodes/{node.id}/image/file"

    usage = session.exec(select(LlmUsage).where(LlmUsage.task == "image")).all()
    assert len(usage) == 1
    assert usage[0].provider == "fake"


def test_image_generate_skips_when_present_unless_regenerate(client, auth, session):
    node = KnowledgeNode(
        name="Softmax",
        name_key="softmax",
        description="Normalize scores.",
        image_url="/knowledge/nodes/x/image/file",
        image_bytes=b"\x89PNG\r\n\x1a\n",
    )
    session.add(node)
    session.commit()

    again = client.post(
        f"/api/v1/knowledge/nodes/{node.id}/image",
        headers=auth,
        json={"generate": True},
    )
    assert again.status_code == 200
    assert again.json()["incomplete"] is False
    assert again.json().get("job_id") is None

    regen = client.post(
        f"/api/v1/knowledge/nodes/{node.id}/image",
        headers=auth,
        json={"regenerate": True},
    )
    assert regen.status_code == 202
    assert regen.json()["job_id"]


def test_image_generate_coalesces(client, auth, other_auth, session):
    node = KnowledgeNode(name="Softmax", name_key="softmax", description="Normalize scores.")
    session.add(node)
    session.commit()

    first = client.post(
        f"/api/v1/knowledge/nodes/{node.id}/image",
        headers=auth,
        json={"generate": True},
    )
    second = client.post(
        f"/api/v1/knowledge/nodes/{node.id}/image",
        headers=other_auth,
        json={"generate": True},
    )
    assert first.status_code == 202
    assert second.status_code == 202
    assert first.json()["job_id"] == second.json()["job_id"]
    assert session.exec(select(func.count()).select_from(GenerationJob)).one() == 1


def test_image_prompt_and_costs():
    prompt = build_topic_image_prompt("Photosynthesis", "How plants make sugar.")
    assert "Photosynthesis" in prompt
    assert "photorealistic" in prompt
    assert "no text" in prompt.lower()
    assert image_cost_usd("gemini-3.1-flash-lite-image") == 0.034
    assert image_cost_usd("gpt-image-2.5-flare", quality="low") == 0.04
    assert get_image_llm("fake").name == "fake"
