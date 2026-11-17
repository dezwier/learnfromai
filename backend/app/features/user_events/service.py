"""Record and validate user–topic interaction events."""

from __future__ import annotations

from datetime import datetime
from typing import Any
from uuid import UUID

from sqlmodel import Session, select

from app.core.errors import AppError
from app.core.time import utcnow
from app.features.accounts.models import User
from app.features.knowledge_graph.node_models import KnowledgeNode
from app.features.user_events.models import (
    CHECK_EVENT_KINDS,
    CLIENT_EVENT_KINDS,
    MAX_EVENTS_PER_REQUEST,
    OPEN_SOURCES,
    UserTopicEvent,
)


def record_focus(session: Session, *, user: User, node_id: UUID) -> UserTopicEvent:
    """Append a focus event when a neighborhood opens on a topic."""
    now = utcnow()
    event = UserTopicEvent(
        user_id=user.id,
        node_id=node_id,
        kind="focus",
        payload={},
        occurred_at=now,
        created_at=now,
    )
    session.add(event)
    return event


def record_events(
    session: Session,
    *,
    user: User,
    items: list[dict[str, Any]],
) -> list[UserTopicEvent]:
    """Validate and append client-submitted open/learn/example/check events."""
    if len(items) > MAX_EVENTS_PER_REQUEST:
        raise AppError(
            "INVALID_EVENTS",
            f"At most {MAX_EVENTS_PER_REQUEST} events per request",
            400,
        )

    now = utcnow()
    node_ids: set[UUID] = set()
    prepared: list[tuple[UUID, str, dict, datetime]] = []

    for index, raw in enumerate(items):
        if not isinstance(raw, dict):
            raise AppError("INVALID_EVENTS", f"Event {index} must be an object", 400)

        kind = str(raw.get("kind") or "").strip()
        if kind not in CLIENT_EVENT_KINDS:
            raise AppError(
                "INVALID_EVENTS",
                f"Event {index} has unsupported kind",
                400,
                {"kind": kind, "allowed": list(CLIENT_EVENT_KINDS)},
            )

        node_raw = raw.get("node_id")
        try:
            node_id = UUID(str(node_raw))
        except (TypeError, ValueError) as exc:
            raise AppError(
                "INVALID_EVENTS",
                f"Event {index} has invalid node_id",
                400,
            ) from exc

        payload = _normalize_payload(kind, raw.get("payload"), index=index)
        occurred_at = _parse_occurred_at(raw.get("occurred_at"), fallback=now, index=index)
        node_ids.add(node_id)
        prepared.append((node_id, kind, payload, occurred_at))

    if node_ids:
        existing = set(
            session.exec(select(KnowledgeNode.id).where(KnowledgeNode.id.in_(node_ids))).all()
        )
        missing = node_ids - existing
        if missing:
            raise AppError(
                "INVALID_EVENTS",
                "Unknown node_id",
                400,
                {"node_ids": [str(nid) for nid in sorted(missing)]},
            )

    events: list[UserTopicEvent] = []
    for node_id, kind, payload, occurred_at in prepared:
        event = UserTopicEvent(
            user_id=user.id,
            node_id=node_id,
            kind=kind,
            payload=payload,
            occurred_at=occurred_at,
            created_at=now,
        )
        session.add(event)
        events.append(event)
    return events


def _normalize_payload(kind: str, raw: Any, *, index: int) -> dict:
    if raw is None:
        payload: dict = {}
    elif isinstance(raw, dict):
        payload = dict(raw)
    else:
        raise AppError("INVALID_EVENTS", f"Event {index} payload must be an object", 400)

    if kind == "open":
        source = str(payload.get("source") or "").strip()
        if source not in OPEN_SOURCES:
            raise AppError(
                "INVALID_EVENTS",
                f"Event {index} open payload requires source",
                400,
                {"allowed": list(OPEN_SOURCES)},
            )
        return {"source": source}

    if kind not in CHECK_EVENT_KINDS:
        return _with_optional_pack_index(payload)

    if "correct" not in payload:
        raise AppError(
            "INVALID_EVENTS",
            f"Event {index} check payload requires correct",
            400,
        )
    correct = payload["correct"]
    if not isinstance(correct, bool):
        raise AppError(
            "INVALID_EVENTS",
            f"Event {index} correct must be a boolean",
            400,
        )

    out: dict[str, Any] = {"correct": correct}
    pack_index = _optional_pack_index(payload, index=index)
    if pack_index is not None:
        out["pack_index"] = pack_index

    choice_index = payload.get("choice_index")
    if choice_index is not None:
        try:
            out["choice_index"] = int(choice_index)
        except (TypeError, ValueError) as exc:
            raise AppError(
                "INVALID_EVENTS",
                f"Event {index} choice_index must be an integer",
                400,
            ) from exc

    if "answer_bool" in payload:
        answer_bool = payload["answer_bool"]
        if not isinstance(answer_bool, bool):
            raise AppError(
                "INVALID_EVENTS",
                f"Event {index} answer_bool must be a boolean",
                400,
            )
        out["answer_bool"] = answer_bool

    if "answer_text" in payload:
        out["answer_text"] = str(payload.get("answer_text") or "")

    if (
        "choice_index" not in out
        and "answer_bool" not in out
        and "answer_text" not in out
    ):
        raise AppError(
            "INVALID_EVENTS",
            f"Event {index} check payload requires choice_index, answer_bool, or answer_text",
            400,
        )

    return out


def _optional_pack_index(payload: dict, *, index: int) -> int | None:
    if "pack_index" not in payload or payload.get("pack_index") is None:
        return None
    try:
        return int(payload["pack_index"])
    except (TypeError, ValueError) as exc:
        raise AppError(
            "INVALID_EVENTS",
            f"Event {index} pack_index must be an integer",
            400,
        ) from exc


def _with_optional_pack_index(payload: dict) -> dict:
    """Keep client pack_index on learn/example (and any other non-check) payloads."""
    if "pack_index" not in payload or payload.get("pack_index") is None:
        return dict(payload)
    try:
        pack_index = int(payload["pack_index"])
    except (TypeError, ValueError):
        return {k: v for k, v in payload.items() if k != "pack_index"}
    out = dict(payload)
    out["pack_index"] = pack_index
    return out


def _parse_occurred_at(raw: Any, *, fallback: datetime, index: int) -> datetime:
    if raw is None or raw == "":
        return fallback
    if isinstance(raw, datetime):
        return raw if raw.tzinfo else raw.replace(tzinfo=fallback.tzinfo)
    text = str(raw).strip()
    if text.endswith("Z"):
        text = text[:-1] + "+00:00"
    try:
        parsed = datetime.fromisoformat(text)
    except ValueError as exc:
        raise AppError(
            "INVALID_EVENTS",
            f"Event {index} has invalid occurred_at",
            400,
        ) from exc
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=fallback.tzinfo)
    return parsed
