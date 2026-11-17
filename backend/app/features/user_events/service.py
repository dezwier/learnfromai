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
    """Validate and append client-submitted learn/example/check events."""
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

    if kind not in CHECK_EVENT_KINDS:
        return payload

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

    choice_index = payload.get("choice_index")
    if choice_index is None:
        raise AppError(
            "INVALID_EVENTS",
            f"Event {index} check payload requires choice_index",
            400,
        )
    try:
        choice_int = int(choice_index)
    except (TypeError, ValueError) as exc:
        raise AppError(
            "INVALID_EVENTS",
            f"Event {index} choice_index must be an integer",
            400,
        ) from exc

    return {"correct": correct, "choice_index": choice_int}


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
