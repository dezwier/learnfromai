from __future__ import annotations

from typing import Any
from uuid import UUID

from fastapi import APIRouter, Depends, Response
from pydantic import BaseModel, Field
from sqlmodel import Session

from app.core.db import get_session
from app.core.errors import AppError, forbidden, not_found
from app.core.security import get_current_user
from app.features.accounts.firebase_auth import exchange_firebase_token
from app.features.accounts.models import User
from app.features.accounts.profile import merge_profile_prefs, profile_fields
from app.features.knowledge_graph.graph import focus_or_enqueue, graph_for_focus
from app.features.knowledge_graph.node_ops import delete_knowledge_node, update_knowledge_node
from app.features.knowledge_graph.preferences import merge_neighborhood_prefs, neighborhood_counts
from app.features.knowledge_graph.search import search_nodes
from app.features.knowledge_graph.service import remove_concept, remove_request
from app.features.knowledge_graph.workspace import workspace_graph
from app.features.platform.models import GenerationJob
from app.features.platform.neighborhood_llm import parse_uuid

router = APIRouter()


class FirebaseBody(BaseModel):
    id_token: str


class ExtendBody(BaseModel):
    instruction: str = Field(min_length=1, max_length=4000)
    parent_concept_id: UUID | None = None


class FocusBody(BaseModel):
    topic: str | None = Field(default=None, max_length=200)
    node_id: UUID | None = None


class KnowledgeNodePatchBody(BaseModel):
    name: str | None = Field(default=None, max_length=200)
    description: str | None = Field(default=None, max_length=8000)


class PreferencesBody(BaseModel):
    neighborhood: dict[str, Any] | None = None


class MePatchBody(BaseModel):
    username: str | None = Field(default=None, max_length=200)
    full_name: str | None = Field(default=None, max_length=200)
    photo_url: str | None = Field(default=None, max_length=2000)
    display_name: str | None = Field(default=None, max_length=200)
    timezone: str | None = Field(default=None, max_length=64)


@router.post("/auth/firebase")
def auth_firebase(body: FirebaseBody, session: Session = Depends(get_session)):
    user, token = exchange_firebase_token(session, body.id_token)
    session.commit()
    return {"access_token": token, "token_type": "bearer", "user": _user_payload(user)}


@router.get("/me")
def me(user: User = Depends(get_current_user)):
    return _user_payload(user)


@router.patch("/me")
def patch_me(
    body: MePatchBody,
    user: User = Depends(get_current_user),
    session: Session = Depends(get_session),
):
    updates = body.model_dump(exclude_unset=True)
    if "display_name" in updates and updates["display_name"] is not None:
        user.display_name = str(updates["display_name"]).strip() or user.display_name
    if "timezone" in updates and updates["timezone"]:
        user.timezone = str(updates["timezone"]).strip() or user.timezone
    if "full_name" in updates and updates["full_name"] is not None:
        # Keep legacy display_name in sync with full name when provided.
        name = str(updates["full_name"]).strip()
        if name:
            user.display_name = name
    profile_updates = {key: updates[key] for key in ("username", "full_name", "photo_url") if key in updates}
    if profile_updates:
        user.preferences = merge_profile_prefs(user.preferences, profile_updates)
    session.add(user)
    session.commit()
    session.refresh(user)
    return _user_payload(user)


@router.get("/me/preferences")
def get_preferences(user: User = Depends(get_current_user)):
    return {"neighborhood": neighborhood_counts(user)}


@router.patch("/me/preferences")
def patch_preferences(
    body: PreferencesBody,
    user: User = Depends(get_current_user),
    session: Session = Depends(get_session),
):
    updates = body.neighborhood or {}
    user.preferences = merge_neighborhood_prefs(user.preferences, updates)
    session.add(user)
    session.commit()
    session.refresh(user)
    return {"neighborhood": neighborhood_counts(user)}


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


@router.post("/knowledge/focus")
def knowledge_focus(
    body: FocusBody,
    response: Response,
    user: User = Depends(get_current_user),
    session: Session = Depends(get_session),
):
    payload, status = focus_or_enqueue(session, user=user, topic=body.topic, node_id=body.node_id)
    session.commit()
    response.status_code = status
    return payload


@router.get("/knowledge/nodes")
def knowledge_nodes(
    q: str = "",
    limit: int = 8,
    user: User = Depends(get_current_user),
    session: Session = Depends(get_session),
):
    _ = user
    return {"nodes": search_nodes(session, q, limit=limit)}


@router.patch("/knowledge/nodes/{node_id}")
def patch_knowledge_node(
    node_id: UUID,
    body: KnowledgeNodePatchBody,
    user: User = Depends(get_current_user),
    session: Session = Depends(get_session),
):
    _ = user
    if body.name is None and body.description is None:
        raise AppError("VALIDATION_ERROR", "Provide a name and/or description", 422)
    payload = update_knowledge_node(
        session,
        node_id,
        name=body.name,
        description=body.description,
    )
    session.commit()
    return payload


@router.delete("/knowledge/nodes/{node_id}")
def delete_knowledge_node_route(
    node_id: UUID,
    user: User = Depends(get_current_user),
    session: Session = Depends(get_session),
):
    _ = user
    payload = delete_knowledge_node(session, node_id)
    session.commit()
    return payload


@router.get("/knowledge/graph")
def knowledge_graph(
    response: Response,
    topic: str | None = None,
    node_id: UUID | None = None,
    focus_qid: str | None = None,
    category_id: str | None = None,
    user: User = Depends(get_current_user),
    session: Session = Depends(get_session),
):
    resolved = node_id or parse_uuid(focus_qid) or parse_uuid(category_id)
    payload, status = focus_or_enqueue(session, user=user, topic=topic, node_id=resolved)
    session.commit()
    response.status_code = status
    return payload


@router.get("/knowledge/graph/{focus_id}")
def knowledge_graph_focus(
    focus_id: UUID,
    user: User = Depends(get_current_user),
    session: Session = Depends(get_session),
):
    payload = graph_for_focus(session, user=user, focus_id=focus_id)
    session.commit()
    return payload


@router.post("/graph/extend", status_code=410)
def extend(body: ExtendBody, user: User = Depends(get_current_user), session: Session = Depends(get_session)):
    _ = (body, user, session)
    raise AppError(
        "GONE",
        "Use topic search. Neighborhood generation runs as a background job.",
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
    profile = profile_fields(user)
    return {
        "id": str(user.id),
        "email": profile["email"],
        "display_name": profile["display_name"],
        "username": profile["username"],
        "full_name": profile["full_name"],
        "photo_url": profile["photo_url"],
        "timezone": user.timezone,
        "preferences": {"neighborhood": neighborhood_counts(user)},
    }
