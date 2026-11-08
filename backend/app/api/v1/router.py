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
from app.features.graph_extend.models import ExtendRequest
from app.features.knowledge_graph.models import Concept
from app.features.knowledge_graph.service import clear_graph, remove_concept, shared_graph
from app.features.knowledge_graph.workspace import workspace_graph
from app.features.platform.jobs import enqueue
from app.features.platform.llm import assert_user_quota
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


@router.post("/graph/extend", status_code=202)
def extend(body: ExtendBody, user: User = Depends(get_current_user), session: Session = Depends(get_session)):
    instruction = body.instruction.strip()
    if not instruction:
        raise AppError("VALIDATION_ERROR", "Instruction is empty", 422)
    assert_user_quota(session, user.id)
    graph = shared_graph(session)
    parent_id = body.parent_concept_id
    if parent_id is not None:
        parent = session.get(Concept, parent_id)
        if parent is None or parent.origin_graph_id != graph.id:
            raise not_found("Parent concept not found")
    request = ExtendRequest(
        user_id=user.id,
        graph_id=graph.id,
        parent_concept_id=parent_id,
        instruction=instruction,
        status="queued",
    )
    session.add(request)
    session.flush()
    job = enqueue(
        session,
        job_type="expand_graph",
        user_id=user.id,
        payload={"request_id": str(request.id)},
    )
    request.job_id = job.id
    session.commit()
    return {"request_id": str(request.id), "job_id": str(job.id)}


@router.delete("/graph")
def delete_graph(user: User = Depends(get_current_user), session: Session = Depends(get_session)):
    _ = user
    removed = clear_graph(session)
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
