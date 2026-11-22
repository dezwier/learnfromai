"""Worker: generate a shared image for one atomic learning pack."""

from __future__ import annotations

from sqlmodel import Session, select

from app.core.errors import AppError
from app.features.knowledge_graph.neighborhood import set_progress
from app.features.knowledge_graph.node_models import KnowledgeNode
from app.features.node_image.pack_service import (
    learn_bit_text,
    pack_image_path_for,
    pack_thumb_path_for,
    store_pack_image,
)
from app.features.platform.image_llm import build_pack_image_prompt, get_image_llm
from app.features.platform.jobs import renew_lease
from app.features.platform.llm import assert_user_quota, bind_usage_sink, maybe_record_usage
from app.features.platform.models import GenerationJob, GenerationJobWatcher
from app.features.platform.neighborhood_llm import parse_uuid


def generate_pack_image(session: Session, job: GenerationJob) -> dict:
    payload = job.payload or {}
    user_id = job.user_id or parse_uuid(payload.get("requested_by"))
    if user_id is None:
        watcher = session.exec(
            select(GenerationJobWatcher).where(GenerationJobWatcher.job_id == job.id)
        ).first()
        if watcher is not None:
            user_id = watcher.user_id
    if user_id is None:
        raise AppError("VALIDATION_ERROR", "Job is missing a user", 422)

    assert_user_quota(session, user_id)
    node_id = parse_uuid(payload.get("node_id"))
    if node_id is None:
        raise AppError("VALIDATION_ERROR", "Job is missing node_id", 422)
    try:
        pack_index = int(payload.get("pack_index") or 0)
    except (TypeError, ValueError):
        pack_index = 0
    if pack_index < 1:
        raise AppError("VALIDATION_ERROR", "Job is missing pack_index", 422)

    set_progress(session, job, stage="resolve", message="Loading atom…", fraction=0.1)
    node = session.get(KnowledgeNode, node_id)
    if node is None:
        raise AppError("NOT_FOUND", "Topic not found", 404, {"terminal": True})
    learn_title, learn_markdown = learn_bit_text(session, node_id, pack_index)

    from app.features.accounts.models import User
    from app.features.knowledge_graph.preferences import preferred_llm_provider

    user = session.get(User, user_id)
    llm = get_image_llm(preferred_llm_provider(user))
    setattr(llm, "heartbeat", lambda: renew_lease(session, job))
    bind_usage_sink(llm, session, user_id=user_id, job_id=job.id, task="image")
    set_progress(session, job, stage="generate", message="Creating atom image…", fraction=0.4)
    assert_user_quota(session, user_id)
    prompt = build_pack_image_prompt(
        node.name,
        node.description,
        learn_title=learn_title,
        learn_markdown=learn_markdown,
    )
    png, usage = llm.generate_image(node.name, node.description, prompt=prompt)
    renew_lease(session, job)
    maybe_record_usage(session, llm, user_id=user_id, job_id=job.id, task="image", usage=usage)
    session.commit()
    assert_user_quota(session, user_id)

    set_progress(session, job, stage="persist", message="Saving atom image…", fraction=0.85)
    node = session.get(KnowledgeNode, node_id)
    if node is None:
        raise AppError("NOT_FOUND", "Topic not found", 404, {"terminal": True})
    store_pack_image(session, node_id=node_id, pack_index=pack_index, raw=png)
    set_progress(session, job, stage="done", message="Atom image ready", fraction=1.0)
    session.commit()
    return {
        "node_id": str(node_id),
        "pack_index": pack_index,
        "image_url": pack_image_path_for(node_id, pack_index),
        "image_thumb_url": pack_thumb_path_for(node_id, pack_index),
        "skipped": False,
    }
