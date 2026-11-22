"""Load and enqueue shared tile content (learning atoms)."""

from __future__ import annotations

from uuid import UUID

from sqlmodel import Session, col, select

from app.core.errors import AppError, not_found
from app.features.accounts.models import User
from app.features.content.models import (
    CHECK_KINDS,
    CONTENT_KINDS,
    DEFAULT_BAND,
    LEGACY_CHECK_KIND,
    RECIPE_VERSION,
    KnowledgeBit,
    pack_atomically_complete,
)
from app.features.knowledge_graph.node_models import KnowledgeNode
from app.features.platform.jobs import enqueue, ensure_watcher
from app.features.platform.models import GenerationJob


def _present_kinds(rows: list[KnowledgeBit]) -> set[str]:
    kinds = {row.kind for row in rows}
    if LEGACY_CHECK_KIND in kinds and "check1" not in kinds:
        kinds.add("check1")
    return kinds


def _bit_payload(row: KnowledgeBit) -> dict:
    kind = "check1" if row.kind == LEGACY_CHECK_KIND else row.kind
    return {
        "id": str(row.id),
        "kind": kind,
        "pack_index": row.pack_index,
        "band": row.band,
        "recipe_version": row.recipe_version,
        "position": row.position,
        "body": row.body if isinstance(row.body, dict) else {},
    }


def _dedupe_bits(bits: list[dict]) -> list[dict]:
    seen: set[str] = set()
    deduped: list[dict] = []
    for bit in bits:
        if bit["kind"] in seen:
            continue
        seen.add(bit["kind"])
        deduped.append(bit)
    return deduped


def _pack_title(bits: list[dict]) -> str | None:
    for bit in bits:
        if bit["kind"] != "learn":
            continue
        body = bit.get("body") if isinstance(bit.get("body"), dict) else {}
        title = str(body.get("title") or "").strip()
        return title or None
    return None


def _rows_for_node(
    session: Session,
    node_id: UUID,
    *,
    band: str,
    recipe_version: int,
) -> list[KnowledgeBit]:
    return list(
        session.exec(
            select(KnowledgeBit)
            .where(
                KnowledgeBit.node_id == node_id,
                KnowledgeBit.band == band,
                KnowledgeBit.recipe_version == recipe_version,
            )
            .order_by(
                col(KnowledgeBit.pack_index),
                col(KnowledgeBit.position),
                col(KnowledgeBit.kind),
            )
        ).all()
    )


def is_playable_check_body(body: object) -> bool:
    """True for mc / true_false / one-word cloze MC — not free-text cloze."""
    if not isinstance(body, dict):
        return False
    raw_type = str(body.get("type") or "").strip().lower()
    if not raw_type:
        if "choices" in body or "answer_index" in body:
            raw_type = "mc"
        elif "statement" in body or isinstance(body.get("answer"), bool):
            raw_type = "true_false"
        elif "prompt" in body:
            raw_type = "cloze"
        else:
            raw_type = "mc"
    if raw_type == "true_false":
        return True
    if raw_type == "mc":
        choices = body.get("choices")
        return isinstance(choices, list) and len(choices) >= 2
    if raw_type == "cloze":
        choices = body.get("choices")
        return (
            isinstance(choices, list)
            and len(choices) >= 2
            and "answer_index" in body
        )
    return False


def is_free_text_cloze_body(body: object) -> bool:
    """Legacy open-answer cloze (no one-word MC choices)."""
    if not isinstance(body, dict):
        return False
    raw_type = str(body.get("type") or "").strip().lower()
    if raw_type == "cloze":
        return not is_playable_check_body(body)
    if raw_type:
        return False
    # Untyped prompt + free-text answer.
    return "prompt" in body and not isinstance(body.get("choices"), list)


def missing_content_kinds(
    session: Session,
    node_id: UUID,
    *,
    pack_index: int,
    band: str = DEFAULT_BAND,
    recipe_version: int = RECIPE_VERSION,
) -> list[str]:
    """Kinds still needed so the pack is content-complete.

    Complete = learn + at least one playable check (fewer than three is fine).
    """
    rows = [
        row
        for row in _rows_for_node(session, node_id, band=band, recipe_version=recipe_version)
        if row.pack_index == pack_index
    ]
    present = _present_kinds(rows)
    missing: list[str] = []
    if "learn" not in present:
        missing.append("learn")
    playable_checks = [
        row
        for row in rows
        if (row.kind in CHECK_KINDS or row.kind == LEGACY_CHECK_KIND)
        and is_playable_check_body(row.body)
    ]
    if not playable_checks:
        missing.append("check1")
    return missing


def pack_indexes(
    session: Session,
    node_id: UUID,
    *,
    band: str = DEFAULT_BAND,
    recipe_version: int = RECIPE_VERSION,
) -> list[int]:
    rows = _rows_for_node(session, node_id, band=band, recipe_version=recipe_version)
    return sorted({row.pack_index for row in rows})


def next_pack_index(
    session: Session,
    node_id: UUID,
    *,
    band: str = DEFAULT_BAND,
    recipe_version: int = RECIPE_VERSION,
) -> int:
    indexes = pack_indexes(session, node_id, band=band, recipe_version=recipe_version)
    return (max(indexes) + 1) if indexes else 1


def first_incomplete_pack(
    session: Session,
    node_id: UUID,
    *,
    band: str = DEFAULT_BAND,
    recipe_version: int = RECIPE_VERSION,
) -> int | None:
    indexes = pack_indexes(session, node_id, band=band, recipe_version=recipe_version)
    for pack_index in indexes:
        if missing_content_kinds(
            session, node_id, pack_index=pack_index, band=band, recipe_version=recipe_version
        ):
            return pack_index
    return None


def is_pack_complete(
    session: Session,
    node_id: UUID,
    *,
    pack_index: int,
    band: str = DEFAULT_BAND,
    recipe_version: int = RECIPE_VERSION,
) -> bool:
    return not missing_content_kinds(
        session,
        node_id,
        pack_index=pack_index,
        band=band,
        recipe_version=recipe_version,
    )


def is_content_complete(
    session: Session,
    node_id: UUID,
    *,
    band: str = DEFAULT_BAND,
    recipe_version: int = RECIPE_VERSION,
) -> bool:
    indexes = pack_indexes(session, node_id, band=band, recipe_version=recipe_version)
    if not indexes:
        return False
    return all(
        is_pack_complete(
            session, node_id, pack_index=pack_index, band=band, recipe_version=recipe_version
        )
        for pack_index in indexes
    )


def completed_pack_indexes(
    session: Session,
    *,
    user_id: UUID,
    node_id: UUID,
) -> list[int]:
    """Pack indexes where the user has recorded learn + any one check."""
    from app.features.user_events.models import UserTopicEvent

    rows = list(
        session.exec(
            select(UserTopicEvent).where(
                UserTopicEvent.user_id == user_id,
                UserTopicEvent.node_id == node_id,
                col(UserTopicEvent.kind).in_(list(CONTENT_KINDS) + [LEGACY_CHECK_KIND]),
            )
        ).all()
    )
    by_pack: dict[int, set[str]] = {}
    for row in rows:
        payload = row.payload if isinstance(row.payload, dict) else {}
        try:
            pack_index = int(payload.get("pack_index") or 1)
        except (TypeError, ValueError):
            pack_index = 1
        kind = "check1" if row.kind == LEGACY_CHECK_KIND else row.kind
        if kind not in CONTENT_KINDS:
            continue
        by_pack.setdefault(pack_index, set()).add(kind)
    return sorted(pack for pack, kinds in by_pack.items() if pack_atomically_complete(kinds))


def content_for_node(
    session: Session,
    node_id: UUID,
    *,
    user_id: UUID | None = None,
    band: str = DEFAULT_BAND,
    recipe_version: int = RECIPE_VERSION,
) -> dict:
    node = session.get(KnowledgeNode, node_id)
    if node is None:
        raise not_found("Topic not found")
    rows = _rows_for_node(session, node_id, band=band, recipe_version=recipe_version)
    by_pack: dict[int, list[dict]] = {}
    for row in rows:
        payload = _bit_payload(row)
        kind = payload["kind"]
        if kind in CHECK_KINDS and not is_playable_check_body(payload.get("body")):
            continue
        by_pack.setdefault(row.pack_index, []).append(payload)
    packs: list[dict] = []
    for pack_index in sorted(by_pack):
        bits = _dedupe_bits(by_pack[pack_index])
        incomplete = bool(
            missing_content_kinds(
                session,
                node_id,
                pack_index=pack_index,
                band=band,
                recipe_version=recipe_version,
            )
        )
        from app.features.node_image.pack_service import pack_image_fields

        image_fields = pack_image_fields(session, node, pack_index)
        packs.append(
            {
                "pack_index": pack_index,
                "incomplete": incomplete,
                "title": _pack_title(bits),
                "bits": bits,
                "image_url": image_fields.get("image_url"),
                "image_thumb_url": image_fields.get("image_thumb_url"),
                "pack_image_url": image_fields.get("pack_image_url"),
                "pack_image_thumb_url": image_fields.get("pack_image_thumb_url"),
            }
        )
    completed = (
        completed_pack_indexes(session, user_id=user_id, node_id=node_id)
        if user_id is not None
        else []
    )
    return {
        "node_id": str(node_id),
        "band": band,
        "recipe_version": recipe_version,
        "pack_count": len(packs),
        "incomplete": not is_content_complete(
            session, node_id, band=band, recipe_version=recipe_version
        ),
        "completed_packs": completed,
        "packs": packs,
    }


def existing_check_bodies(
    session: Session,
    node_id: UUID,
    *,
    pack_index: int,
    band: str = DEFAULT_BAND,
    recipe_version: int = RECIPE_VERSION,
) -> dict[str, dict]:
    """Return check1/2/3 bodies already stored for one pack (legacy check → check1)."""
    payload = content_for_node(session, node_id, band=band, recipe_version=recipe_version)
    out: dict[str, dict] = {}
    for pack in payload["packs"]:
        if pack["pack_index"] != pack_index:
            continue
        for bit in pack["bits"]:
            kind = bit["kind"]
            if kind in CHECK_KINDS and isinstance(bit.get("body"), dict):
                out[kind] = bit["body"]
    return out


def existing_pack_digests(
    session: Session,
    node_id: UUID,
    *,
    band: str = DEFAULT_BAND,
    recipe_version: int = RECIPE_VERSION,
    exclude_pack_index: int | None = None,
) -> list[dict]:
    """Compact digests of other packs for anti-overlap prompting."""
    payload = content_for_node(session, node_id, band=band, recipe_version=recipe_version)
    digests: list[dict] = []
    for pack in payload["packs"]:
        if exclude_pack_index is not None and pack["pack_index"] == exclude_pack_index:
            continue
        learn_md = ""
        learn_title = pack.get("title")
        check_stems: list[str] = []
        for bit in pack["bits"]:
            body = bit.get("body") if isinstance(bit.get("body"), dict) else {}
            if bit["kind"] == "learn":
                learn_md = str(body.get("markdown") or "").strip()
                if not learn_title:
                    learn_title = str(body.get("title") or "").strip() or None
            if bit["kind"] in CHECK_KINDS:
                stem = (
                    str(body.get("question") or body.get("statement") or body.get("prompt") or "")
                    .strip()
                )
                if stem:
                    check_stems.append(stem)
        snippet = learn_md.split("\n", 1)[0][:180] if learn_md else ""
        digests.append(
            {
                "pack_index": pack["pack_index"],
                "title": learn_title,
                "learn_snippet": snippet,
                "check_stems": check_stems,
            }
        )
    return digests


def enqueue_content_expand(
    session: Session,
    *,
    user: User,
    node_id: UUID,
    band: str = DEFAULT_BAND,
    recipe_version: int = RECIPE_VERSION,
    new_pack: bool = False,
) -> tuple[dict, int]:
    """Return (payload, status). 200 content or 202 job."""
    node = session.get(KnowledgeNode, node_id)
    if node is None:
        raise not_found("Topic not found")

    indexes = pack_indexes(session, node_id, band=band, recipe_version=recipe_version)
    incomplete = first_incomplete_pack(
        session, node_id, band=band, recipe_version=recipe_version
    )

    if new_pack:
        if incomplete is not None:
            raise AppError(
                "VALIDATION_ERROR",
                "Finish the incomplete atom before generating another",
                422,
            )
        pack_index = next_pack_index(
            session, node_id, band=band, recipe_version=recipe_version
        )
        missing = list(CONTENT_KINDS)
    else:
        if incomplete is not None:
            pack_index = incomplete
            missing = missing_content_kinds(
                session,
                node_id,
                pack_index=pack_index,
                band=band,
                recipe_version=recipe_version,
            )
        elif not indexes:
            pack_index = 1
            missing = list(CONTENT_KINDS)
        else:
            return content_for_node(
                session,
                node_id,
                user_id=user.id,
                band=band,
                recipe_version=recipe_version,
            ), 200

    if not missing:
        return content_for_node(
            session,
            node_id,
            user_id=user.id,
            band=band,
            recipe_version=recipe_version,
        ), 200

    job = _enqueue(
        session,
        user=user,
        node=node,
        band=band,
        recipe_version=recipe_version,
        pack_index=pack_index,
        missing=missing,
    )
    return {
        "status": "queued",
        "job_id": str(job.id),
        "focus_node_id": str(node.id),
        "pack_index": pack_index,
        "progress": job.progress
        or {"stage": "queued", "message": "Waiting for a worker…", "fraction": 0},
    }, 202


def content_or_expand(
    session: Session,
    *,
    user: User,
    node_id: UUID,
    expand: bool = False,
    new_pack: bool = False,
    band: str = DEFAULT_BAND,
    recipe_version: int = RECIPE_VERSION,
) -> tuple[dict, int]:
    if not expand:
        return content_for_node(
            session,
            node_id,
            user_id=user.id,
            band=band,
            recipe_version=recipe_version,
        ), 200
    return enqueue_content_expand(
        session,
        user=user,
        node_id=node_id,
        band=band,
        recipe_version=recipe_version,
        new_pack=new_pack,
    )


def _enqueue(
    session: Session,
    *,
    user: User,
    node: KnowledgeNode,
    band: str,
    recipe_version: int,
    pack_index: int,
    missing: list[str],
) -> GenerationJob:
    from app.features.platform.jobs import active_job_for_node

    # One content job per node at a time (any pack / any user).
    existing = active_job_for_node(session, job_type="expand_content", node_id=node.id)
    if existing is not None:
        ensure_watcher(
            session,
            job=existing,
            user_id=user.id,
            node_id=node.id,
            title=node.name,
        )
        return existing

    need = "+".join(missing) if missing else "all"
    idempotency = (
        f"expand_content:{node.id}:recipe-{recipe_version}:band-{band}"
        f":pack-{pack_index}:need-{need}"
    )
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
            "pack_index": pack_index,
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
