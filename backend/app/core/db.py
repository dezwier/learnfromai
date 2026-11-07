from __future__ import annotations

from collections.abc import Iterator

from sqlmodel import Session, create_engine

from app.core.config import get_settings

settings = get_settings()
engine = create_engine(settings.sqlalchemy_database_url, pool_pre_ping=True)


def session_scope() -> Iterator[Session]:
    with Session(engine, expire_on_commit=False) as session:
        yield session


def get_session() -> Iterator[Session]:
    yield from session_scope()
