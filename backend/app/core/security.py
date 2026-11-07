from __future__ import annotations

from datetime import timedelta
from uuid import UUID

import jwt
from fastapi import Depends
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from sqlmodel import Session

from app.core.config import get_settings
from app.core.db import get_session
from app.core.errors import AppError
from app.core.time import utcnow

bearer = HTTPBearer(auto_error=False)


def create_access_token(user_id: UUID) -> str:
    settings = get_settings()
    payload = {
        "sub": str(user_id),
        "exp": utcnow() + timedelta(minutes=settings.access_token_expire_minutes),
    }
    return jwt.encode(payload, settings.secret_key, algorithm="HS256")


def decode_access_token(token: str) -> UUID:
    settings = get_settings()
    try:
        payload = jwt.decode(token, settings.secret_key, algorithms=["HS256"])
        return UUID(payload["sub"])
    except (jwt.PyJWTError, ValueError, KeyError) as exc:
        raise AppError("UNAUTHORIZED", "Invalid session", 401) from exc


def get_current_user(
    credentials: HTTPAuthorizationCredentials | None = Depends(bearer),
    session: Session = Depends(get_session),
):
    from app.features.accounts.models import User

    if credentials is None or not credentials.credentials:
        raise AppError("UNAUTHORIZED", "Not authenticated", 401)
    user_id = decode_access_token(credentials.credentials)
    user = session.get(User, user_id)
    if user is None:
        raise AppError("UNAUTHORIZED", "Not authenticated", 401)
    return user
