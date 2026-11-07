from __future__ import annotations

from sqlmodel import Session

from app.features.platform.models import AuditEvent


def write_audit(
    session: Session,
    *,
    actor: str,
    action: str,
    entity_type: str,
    entity_id: str,
    before: dict | None = None,
    after: dict | None = None,
) -> None:
    session.add(
        AuditEvent(
            actor=actor,
            action=action,
            entity_type=entity_type,
            entity_id=entity_id,
            before=before,
            after=after,
        )
    )
