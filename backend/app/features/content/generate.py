"""Worker: generate shared learn / example / check bits for one node."""

from __future__ import annotations

from uuid import UUID

from sqlmodel import Session, select

from app.core.errors import AppError
from app.features.content.models import (
    CONTENT_KINDS,
    DEFAULT_BAND,
    RECIPE_VERSION,
    KnowledgeBit,
)
from app.features.content.service import is_content_complete
from app.features.knowledge_graph.neighborhood import set_progress
from app.features.knowledge_graph.node_models import KnowledgeEdge, KnowledgeNode
from app.features.platform.content_llm import get_content_llm
from app.features.platform.jobs import renew_lease
from app.features.platform.llm import assert_user_quota, record_usage
from app.features.platform.models import GenerationJob, GenerationJobWatcher
from app.features.platform.neighborhood_llm import parse_uuid


def expand_content(session: Session, job: GenerationJob) -> dict:
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
    band = str(payload.get("band") or DEFAULT_BAND)
    recipe_version = int(payload.get("recipe_version") or RECIPE_VERSION)
    if node_id is None:
        raise AppError("VALIDATION_ERROR", "Job is missing node_id", 422)

    set_progress(session, job, stage="resolve", message="Loading topic…", fraction=0.1)
    node = session.get(KnowledgeNode, node_id)
    if node is None:
        raise AppError("NOT_FOUND", "Topic not found", 404, {"terminal": True})

    if is_content_complete(session, node.id, band=band, recipe_version=recipe_version):
        set_progress(session, job, stage="done", message="Content already ready", fraction=1.0)
        session.commit()
        return {"node_id": str(node.id), "skipped": True, "bit_ids": []}

    neighbor_titles = _neighbor_titles(session, node.id)
    llm = get_content_llm()
    setattr(llm, "heartbeat", lambda: renew_lease(session, job))
    set_progress(session, job, stage="generate", message="Writing learn · example · check…", fraction=0.35)
    assert_user_quota(session, user_id)
    bits, usage = llm.generate_bits(node.name, node.description, neighbor_titles)
    renew_lease(session, job)
    record_usage(session, user_id=user_id, job_id=job.id, task="content", provider=llm.name, usage=usage)
    session.commit()
    assert_user_quota(session, user_id)

    set_progress(session, job, stage="persist", message="Saving learning bits…", fraction=0.85)
    bit_ids = _upsert_bits(
        session,
        node_id=node.id,
        bits=bits,
        band=band,
        recipe_version=recipe_version,
    )
    set_progress(session, job, stage="done", message="Learning bits ready", fraction=1.0)
    session.commit()
    return {"node_id": str(node.id), "skipped": False, "bit_ids": bit_ids}


def _neighbor_titles(session: Session, node_id: UUID) -> list[str]:
    edges = list(session.exec(select(KnowledgeEdge).where(KnowledgeEdge.from_id == node_id)).all())
    titles: list[str] = []
    seen: set[UUID] = set()
    for edge in edges:
        if edge.to_id in seen:
            continue
        seen.add(edge.to_id)
        other = session.get(KnowledgeNode, edge.to_id)
        if other is not None and other.name:
            titles.append(other.name)
        if len(titles) >= 12:
            break
    return titles


def _upsert_bits(
    session: Session,
    *,
    node_id: UUID,
    bits: dict,
    band: str,
    recipe_version: int,
) -> list[str]:
    positions = {kind: index for index, kind in enumerate(CONTENT_KINDS)}
    ids: list[str] = []
    for kind in CONTENT_KINDS:
        body = bits.get(kind)
        if not isinstance(body, dict):
            continue
        existing = session.exec(
            select(KnowledgeBit).where(
                KnowledgeBit.node_id == node_id,
                KnowledgeBit.kind == kind,
                KnowledgeBit.band == band,
                KnowledgeBit.recipe_version == recipe_version,
            )
        ).first()
        if existing is None:
            row = KnowledgeBit(
                node_id=node_id,
                kind=kind,
                band=band,
                recipe_version=recipe_version,
                position=positions[kind],
                body=body,
            )
            session.add(row)
            session.flush()
            ids.append(str(row.id))
        else:
            existing.body = body
            existing.position = positions[kind]
            session.add(existing)
            ids.append(str(existing.id))
    return ids
