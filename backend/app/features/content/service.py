"""Load and enqueue shared tile content (learn / example / checks)."""

from __future__ import annotations

from uuid import UUID

from sqlmodel import Session, col, select

from app.core.errors import not_found
from app.features.accounts.models import User
from app.features.content.models import (
    CHECK_KINDS,
    CONTENT_KINDS,
    DEFAULT_BAND,
    LEGACY_CHECK_KIND,
    RECIPE_VERSION,
    KnowledgeBit,
)
from app.features.knowledge_graph.node_models import KnowledgeNode
from app.features.platform.jobs import enqueue, ensure_watcher
from app.features.platform.models import GenerationJob


def _present_kinds(rows: list[KnowledgeBit]) -> set[str]:
    kinds = {row.kind for row in rows}
    if LEGACY_CHECK_KIND in kinds and "check1" not in kinds:
        kinds.add("check1")
    return kinds


def missing_content_kinds(
    session: Session,
    node_id: UUID,
    *,
    band: str = DEFAULT_BAND,
    recipe_version: int = RECIPE_VERSION,
) -> list[str]:
    rows = list(
        session.exec(
            select(KnowledgeBit).where(
                KnowledgeBit.node_id == node_id,
                KnowledgeBit.band == band,
                KnowledgeBit.recipe_version == recipe_version,
            )
        ).all()
    )
    present = _present_kinds(rows)
    missing: list[str] = []
    for kind in CONTENT_KINDS:
        if kind == "check1":
            if "check1" not in present:
                missing.append("check1")
        elif kind not in present:
            missing.append(kind)
    return missing


def is_content_complete(
    session: Session,
    node_id: UUID,
    *,
    band: str = DEFAULT_BAND,
    recipe_version: int = RECIPE_VERSION,
) -> bool:
    return not missing_content_kinds(
        session, node_id, band=band, recipe_version=recipe_version
    )


def content_for_node(
    session: Session,
    node_id: UUID,
    *,
    band: str = DEFAULT_BAND,
    recipe_version: int = RECIPE_VERSION,
) -> dict:
    node = session.get(KnowledgeNode, node_id)
    if node is None:
        raise not_found("Topic not found")
    rows = session.exec(
        select(KnowledgeBit)
        .where(
            KnowledgeBit.node_id == node_id,
            KnowledgeBit.band == band,
            KnowledgeBit.recipe_version == recipe_version,
        )
        .order_by(col(KnowledgeBit.position), col(KnowledgeBit.kind))
    ).all()
    bits = []
    for row in rows:
        kind = "check1" if row.kind == LEGACY_CHECK_KIND else row.kind
        bits.append(
            {
                "id": str(row.id),
                "kind": kind,
                "band": row.band,
                "recipe_version": row.recipe_version,
                "position": row.position,
                "body": row.body if isinstance(row.body, dict) else {},
            }
        )
    # Prefer canonical check1 over a duplicate legacy mapping if both somehow exist.
    seen: set[str] = set()
    deduped = []
    for bit in bits:
        if bit["kind"] in seen:
            continue
        seen.add(bit["kind"])
        deduped.append(bit)
    return {
        "node_id": str(node_id),
        "band": band,
        "recipe_version": recipe_version,
        "incomplete": not is_content_complete(
            session, node_id, band=band, recipe_version=recipe_version
        ),
        "bits": deduped,
    }


def existing_check_bodies(
    session: Session,
    node_id: UUID,
    *,
    band: str = DEFAULT_BAND,
    recipe_version: int = RECIPE_VERSION,
) -> dict[str, dict]:
    """Return check1/2/3 bodies already stored (legacy check → check1)."""
    payload = content_for_node(session, node_id, band=band, recipe_version=recipe_version)
    out: dict[str, dict] = {}
    for bit in payload["bits"]:
        kind = bit["kind"]
        if kind in CHECK_KINDS and isinstance(bit.get("body"), dict):
            out[kind] = bit["body"]
    return out


def enqueue_content_expand(
    session: Session,
    *,
    user: User,
    node_id: UUID,
    band: str = DEFAULT_BAND,
    recipe_version: int = RECIPE_VERSION,
) -> tuple[dict, int]:
    """Return (payload, status). 200 content or 202 job."""
    node = session.get(KnowledgeNode, node_id)
    if node is None:
        raise not_found("Topic not found")
    missing = missing_content_kinds(session, node_id, band=band, recipe_version=recipe_version)
    if not missing:
        return content_for_node(session, node_id, band=band, recipe_version=recipe_version), 200

    job = _enqueue(
        session,
        user=user,
        node=node,
        band=band,
        recipe_version=recipe_version,
        missing=missing,
    )
    return {
        "status": "queued",
        "job_id": str(job.id),
        "focus_node_id": str(node.id),
        "progress": job.progress
        or {"stage": "queued", "message": "Waiting for a worker…", "fraction": 0},
    }, 202


def content_or_expand(
    session: Session,
    *,
    user: User,
    node_id: UUID,
    expand: bool = False,
    band: str = DEFAULT_BAND,
    recipe_version: int = RECIPE_VERSION,
) -> tuple[dict, int]:
    if not expand:
        return content_for_node(session, node_id, band=band, recipe_version=recipe_version), 200
    return enqueue_content_expand(
        session, user=user, node_id=node_id, band=band, recipe_version=recipe_version
    )


def _enqueue(
    session: Session,
    *,
    user: User,
    node: KnowledgeNode,
    band: str,
    recipe_version: int,
    missing: list[str],
) -> GenerationJob:
    need = "+".join(missing) if missing else "all"
    idempotency = f"expand_content:{node.id}:recipe-{recipe_version}:band-{band}:need-{need}"
    job = enqueue(
        session,
        job_type="expand_content",
        user_id=user.id,
        idempotency_key=idempotency,
        shared=True,
        payload={
            "node_id": str(node.id),
            "topic": node.name,
            "requested_by": str(user.id),
            "band": band,
            "recipe_version": recipe_version,
            "missing_kinds": missing,
        },
    )
    ensure_watcher(
        session,
        job=job,
        user_id=user.id,
        node_id=node.id,
        title=node.name,
    )
    return job
