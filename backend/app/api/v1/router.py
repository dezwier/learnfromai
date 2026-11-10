from __future__ import annotations

from uuid import UUID

from fastapi import APIRouter, Depends
from pydantic import BaseModel, Field
from sqlmodel import Session

from app.core.db import get_session
from app.core.errors import AppError, forbidden, not_found
from app.core.security import get_current_user
from app.features.accounts.firebase_auth import exchange_firebase_token
from app.features.accounts.models import User
from app.features.knowledge_graph.items import load_knowledge_graph
from app.features.knowledge_graph.service import remove_concept, remove_request
from app.features.knowledge_graph.workspace import workspace_graph
from app.features.platform.models import GenerationJob

router = APIRouter()


class FirebaseBody(BaseModel):
    id_token: str


class ExtendBody(BaseModel):
    instruction: str = Field(min_length=1, max_length=4000)
    parent_concept_id: UUID | None = None


@router.post("/auth/firebase")
def auth_firebase(body: FirebaseBody, session: Session = Depends(get_session)):
    user, token = exchange_firebase_token(session, body.id_token)
    session.commit()
    return {"access_token": token, "token_type": "bearer", "user": _user_payload(user)}


@router.get("/me")
def me(user: User = Depends(get_current_user)):
    return _user_payload(user)


@router.get("/jobs/{job_id}")
def get_job(job_id: UUID, user: User = Depends(get_current_user), session: Session = Depends(get_session)):
    job = session.get(GenerationJob, job_id)
    if job is None:
        raise not_found("Job not found")
    if job.user_id != user.id and not user.is_admin:
        raise forbidden()
    return {
        "id": str(job.id),
        "type": job.type,
        "state": job.state,
        "progress": job.progress,
        "result": job.result,
        "error_code": job.error_code,
        "error_message": job.error_message,
        "attempts": job.attempts,
    }


@router.get("/workspace/graph")
def workspace(user: User = Depends(get_current_user), session: Session = Depends(get_session)):
    _ = user
    return workspace_graph(session)


@router.get("/knowledge/graph")
def knowledge_graph(
    topic: str | None = None,
    category_id: int | None = None,
    up_depth: int | None = None,
    down_depth: int | None = None,
    user: User = Depends(get_current_user),
    session: Session = Depends(get_session),
):
    payload = load_knowledge_graph(
        session,
        user_id=user.id,
        topic=topic,
        category_id=category_id,
        up_depth=up_depth,
        down_depth=down_depth,
    )
    session.commit()
    return payload


@router.post("/graph/extend", status_code=410)
def extend(body: ExtendBody, user: User = Depends(get_current_user), session: Session = Depends(get_session)):
    _ = (body, user, session)
    raise AppError(
        "GONE",
        "Graph generation has been removed. Search a topic instead.",
        410,
    )


@router.delete("/graph/extend/{request_id}")
def delete_extend(request_id: UUID, user: User = Depends(get_current_user), session: Session = Depends(get_session)):
    _ = user
    removed = remove_request(session, request_id)
    session.commit()
    return removed


@router.delete("/graph/nodes/{concept_id}")
def delete_node(concept_id: UUID, user: User = Depends(get_current_user), session: Session = Depends(get_session)):
    _ = user
    removed = remove_concept(session, concept_id)
    session.commit()
    return removed


def _user_payload(user: User) -> dict:
    return {
        "id": str(user.id),
        "email": user.email,
        "display_name": user.display_name,
        "timezone": user.timezone,
    }
