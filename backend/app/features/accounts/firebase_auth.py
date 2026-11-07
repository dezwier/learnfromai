from __future__ import annotations

import json
import os

from sqlmodel import Session, select

from app.core.config import get_settings
from app.core.errors import AppError
from app.core.security import create_access_token
from app.features.accounts.models import User

_firebase_ready = False


def verify_firebase_id_token(id_token: str) -> dict:
    global _firebase_ready
    settings = get_settings()
    if settings.firebase_auth_emulator_host:
        os.environ["FIREBASE_AUTH_EMULATOR_HOST"] = settings.firebase_auth_emulator_host
    if not settings.firebase_service_account_json and not settings.firebase_auth_emulator_host:
        raise AppError("AUTH_UNAVAILABLE", "Firebase is not configured", 503)
    import firebase_admin
    from firebase_admin import auth, credentials

    if not _firebase_ready:
        if settings.firebase_service_account_json:
            info = json.loads(settings.firebase_service_account_json)
            cred = credentials.Certificate(info)
            firebase_admin.initialize_app(cred)
        else:
            firebase_admin.initialize_app()
        _firebase_ready = True
    return auth.verify_id_token(id_token)


def exchange_firebase_token(session: Session, id_token: str) -> tuple[User, str]:
    decoded = verify_firebase_id_token(id_token)
    uid = decoded.get("uid") or decoded.get("user_id")
    if not uid:
        raise AppError("UNAUTHORIZED", "Firebase token has no uid", 401)
    user = session.exec(select(User).where(User.firebase_uid == uid)).first()
    if user is None:
        email = decoded.get("email")
        user = User(
            firebase_uid=uid,
            email=email,
            display_name=decoded.get("name") or email,
            timezone="UTC",
        )
        session.add(user)
        session.flush()
    return user, create_access_token(user.id)
