"""Worker: generate a shared iconic image for one knowledge node."""

from __future__ import annotations

from sqlmodel import Session, select

from app.core.errors import AppError
from app.features.knowledge_graph.neighborhood import set_progress
from app.features.knowledge_graph.node_models import KnowledgeNode
from app.features.node_image.service import image_path_for
from app.features.platform.image_llm import get_image_llm
from app.features.platform.jobs import renew_lease
from app.features.platform.llm import assert_user_quota, bind_usage_sink, maybe_record_usage
from app.features.platform.models import GenerationJob, GenerationJobWatcher
from app.features.platform.neighborhood_llm import parse_uuid


def generate_image(session: Session, job: GenerationJob) -> dict:
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

    set_progress(session, job, stage="resolve", message="Loading topic…", fraction=0.1)
    node = session.get(KnowledgeNode, node_id)
    if node is None:
        raise AppError("NOT_FOUND", "Topic not found", 404, {"terminal": True})

    from app.features.accounts.models import User
    from app.features.knowledge_graph.preferences import preferred_llm_provider

    user = session.get(User, user_id)
    llm = get_image_llm(preferred_llm_provider(user))
    setattr(llm, "heartbeat", lambda: renew_lease(session, job))
    bind_usage_sink(llm, session, user_id=user_id, job_id=job.id, task="image")
    set_progress(session, job, stage="generate", message="Creating topic image…", fraction=0.4)
    assert_user_quota(session, user_id)
    png, usage = llm.generate_image(node.name, node.description)
    renew_lease(session, job)
    maybe_record_usage(session, llm, user_id=user_id, job_id=job.id, task="image", usage=usage)
    session.commit()
    assert_user_quota(session, user_id)

    set_progress(session, job, stage="persist", message="Saving image…", fraction=0.85)
    node = session.get(KnowledgeNode, node_id)
    if node is None:
        raise AppError("NOT_FOUND", "Topic not found", 404, {"terminal": True})
    node.image_bytes = png
    node.image_url = image_path_for(node.id)
    session.add(node)
    set_progress(session, job, stage="done", message="Topic image ready", fraction=1.0)
    session.commit()
    return {
        "node_id": str(node.id),
        "image_url": node.image_url,
        "skipped": False,
    }
