from __future__ import annotations

from datetime import datetime

from sqlalchemy import Column, DateTime
from sqlalchemy.dialects.postgresql import JSONB

from app.core.time import utcnow


def tz_now() -> Column:
    return Column(DateTime(timezone=True), nullable=False, default=utcnow)


def jsonb(nullable: bool = False) -> Column:
    return Column(JSONB, nullable=nullable)


def created_column() -> datetime:
    return utcnow()
