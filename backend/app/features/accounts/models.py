from __future__ import annotations

from datetime import datetime
from uuid import UUID, uuid4

from sqlalchemy import Column, DateTime, LargeBinary
from sqlalchemy.dialects.postgresql import JSONB
from sqlmodel import Field, SQLModel

from app.core.time import utcnow


class User(SQLModel, table=True):
    __tablename__ = "users"

    id: UUID = Field(default_factory=uuid4, primary_key=True)
    firebase_uid: str = Field(unique=True, index=True)
    email: str | None = None
    display_name: str | None = None
    timezone: str = "UTC"
    is_admin: bool = False
    preferences: dict = Field(default_factory=dict, sa_column=Column(JSONB, nullable=False))
    # Served at GET /me/photo; preferences.profile.photo_url points at that path when set.
    photo_bytes: bytes | None = Field(default=None, sa_column=Column(LargeBinary, nullable=True))
    created_at: datetime = Field(default_factory=utcnow, sa_column=Column(DateTime(timezone=True), nullable=False))
