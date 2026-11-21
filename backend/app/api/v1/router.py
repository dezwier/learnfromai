from __future__ import annotations

from typing import Any
from uuid import UUID

from fastapi import APIRouter, Depends, File, Response, UploadFile
from fastapi.responses import Response as RawResponse
from pydantic import BaseModel, Field
from sqlmodel import Session

from app.core.db import get_session
from app.core.errors import AppError, forbidden, not_found
from app.core.security import get_current_user
from app.features.accounts.firebase_auth import exchange_firebase_token
from app.features.accounts.models import User
from app.features.accounts.photo import (
    clear_photo,
    clear_photo_bytes_if_external_url,
    photo_bytes_for,
    store_uploaded_photo,
)
from app.features.accounts.profile import merge_profile_prefs, profile_fields
from app.features.content.service import content_for_node, content_or_expand
from app.features.knowledge_graph.graph import focus_or_enqueue, graph_for_focus
from app.features.knowledge_graph.node_ops import delete_knowledge_node, update_knowledge_node
from app.features.knowledge_graph.preferences import (
    llm_provider_for,
    merge_llm_provider_pref,
    merge_neighborhood_prefs,
    neighborhood_counts,
)
from app.features.knowledge_graph.search import search_nodes
from app.features.knowledge_graph.service import remove_concept, remove_request
from app.features.knowledge_graph.workspace import workspace_graph
from app.features.node_image.service import (
    image_bytes_for_node,
    image_for_node,
    image_or_generate,
)
from app.features.node_image.upload import upload_node_image
from app.features.platform.jobs import list_and_watch_node_jobs, list_watched_jobs, user_watches_job
from app.features.platform.models import GenerationJob
from app.features.knowledge_graph.node_models import KnowledgeNode
from app.features.platform.neighborhood_llm import parse_uuid
from app.features.learning.service import learning_next
from app.features.reviews.service import distribution_for_user, due_reviews, submit_review
from app.features.user_events.affinity import topic_affinity
from app.features.user_events.service import record_events

router = APIRouter()


class FirebaseBody(BaseModel):
    id_token: str


class ExtendBody(BaseModel):
    instruction: str = Field(min_length=1, max_length=4000)
    parent_concept_id: UUID | None = None


class FocusBody(BaseModel):
    topic: str | None = Field(default=None, max_length=200)
    node_id: UUID | None = None
    expand: bool = False


class KnowledgeNodePatchBody(BaseModel):
    name: str | None = Field(default=None, max_length=200)
    description: str | None = Field(default=None, max_length=8000)


class KnowledgeContentBody(BaseModel):
    expand: bool = False
    new_pack: bool = False


class KnowledgeImageBody(BaseModel):
    generate: bool = False
    regenerate: bool = False


class PreferencesBody(BaseModel):
    neighborhood: dict[str, Any] | None = None
    llm_provider: str | None = None


class MePatchBody(BaseModel):
    username: str | None = Field(default=None, max_length=200)
    full_name: str | None = Field(default=None, max_length=200)
    photo_url: str | None = Field(default=None, max_length=2000)
    display_name: str | None = Field(default=None, max_length=200)
    timezone: str | None = Field(default=None, max_length=64)


class UserEventItem(BaseModel):
    node_id: UUID
    kind: str = Field(min_length=1, max_length=32)
    occurred_at: str | None = None
    payload: dict[str, Any] | None = None


class UserEventsBody(BaseModel):
    events: list[UserEventItem] = Field(default_factory=list, max_length=50)


class ReviewSubmitBody(BaseModel):
    node_id: UUID
    pack_index: int = Field(ge=1)
    correct: bool
    check_kind: str = Field(min_length=1, max_length=16)
    choice_index: int | None = None
    answer_bool: bool | None = None
    answer_text: str | None = None


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
        if "photo_url" in profile_updates:
            clear_photo_bytes_if_external_url(user, profile_updates.get("photo_url"))
        user.preferences = merge_profile_prefs(user.preferences, profile_updates)
    session.add(user)
    session.commit()
    session.refresh(user)
    return _user_payload(user)


@router.get("/me/photo")
def get_me_photo(user: User = Depends(get_current_user)):
    payload, media_type = photo_bytes_for(user)
    return RawResponse(content=payload, media_type=media_type)


@router.put("/me/photo")
async def put_me_photo(
    file: UploadFile = File(...),
    user: User = Depends(get_current_user),
    session: Session = Depends(get_session),
):
    raw = await file.read()
    store_uploaded_photo(session, user, raw, content_type=file.content_type)
    session.commit()
    session.refresh(user)
    return _user_payload(user)


@router.delete("/me/photo")
def delete_me_photo(
    user: User = Depends(get_current_user),
    session: Session = Depends(get_session),
):
    clear_photo(session, user)
    session.commit()
    session.refresh(user)
    return _user_payload(user)


@router.post("/me/events")
def post_me_events(
    body: UserEventsBody,
    user: User = Depends(get_current_user),
    session: Session = Depends(get_session),
):
    items = [item.model_dump(exclude_none=True) for item in body.events]
    recorded = record_events(session, user=user, items=items)
    session.commit()
    return {
        "recorded": len(recorded),
        "ids": [str(event.id) for event in recorded],
    }


@router.get("/me/topic-affinity")
def get_me_topic_affinity(
    limit: int = 24,
    user: User = Depends(get_current_user),
    session: Session = Depends(get_session),
):
    return topic_affinity(session, user=user, limit=limit)


@router.get("/me/learning-next")
def get_me_learning_next(
    seed_node_id: UUID,
    exclude_node_id: UUID | None = None,
    exclude_pack_index: int | None = None,
    opening: bool = False,
    picked_node_id: UUID | None = None,
    user: User = Depends(get_current_user),
    session: Session = Depends(get_session),
):
    return learning_next(
        session,
        user=user,
        seed_node_id=seed_node_id,
        exclude_node_id=exclude_node_id,
        exclude_pack_index=exclude_pack_index,
        opening=opening,
        picked_node_id=picked_node_id,
    )


@router.get("/me/reviews/distribution")
def get_me_reviews_distribution(
    user: User = Depends(get_current_user),
    session: Session = Depends(get_session),
):
    return distribution_for_user(session, user=user)


@router.get("/me/reviews/due")
def get_me_reviews_due(
    limit: int = 10,
    user: User = Depends(get_current_user),
    session: Session = Depends(get_session),
):
    return due_reviews(session, user=user, limit=limit)


@router.post("/me/reviews/submit")
def post_me_reviews_submit(
    body: ReviewSubmitBody,
    user: User = Depends(get_current_user),
    session: Session = Depends(get_session),
):
    answer_fields: dict[str, Any] = {}
    if body.choice_index is not None:
        answer_fields["choice_index"] = body.choice_index
    if body.answer_bool is not None:
        answer_fields["answer_bool"] = body.answer_bool
    if body.answer_text is not None:
        answer_fields["answer_text"] = body.answer_text
    result = submit_review(
        session,
        user=user,
        node_id=body.node_id,
        pack_index=body.pack_index,
        correct=body.correct,
        check_kind=body.check_kind,
        answer_fields=answer_fields,
    )
    session.commit()
    return result


@router.get("/admin/cron-runs/latest")
def get_latest_cron_run(
    user: User = Depends(get_current_user),
    session: Session = Depends(get_session),
):
    if not user.is_admin:
        raise forbidden()
    from app.features.ranking.cron_run import cron_run_payload, latest_cron_run

    run = latest_cron_run(session)
    if run is None:
        return {"run": None}
    return {"run": cron_run_payload(session, run)}


@router.get("/admin/cron-runs/preview")
def get_cron_queue_preview(
    user: User = Depends(get_current_user),
    session: Session = Depends(get_session),
):
    """Admin: a-priori ranked neighbor/learn queues (what Run now would enqueue)."""
    if not user.is_admin:
        raise forbidden()
    from app.features.ranking.cron_run import cron_queue_preview

    return cron_queue_preview(session)


@router.post("/admin/cron-runs/run")
def post_run_cron(
    user: User = Depends(get_current_user),
    session: Session = Depends(get_session),
):
    """Admin: enqueue the daily ranking cron immediately (same as the scheduled job)."""
    if not user.is_admin:
        raise forbidden()
    from app.features.ranking.cron_run import cron_queue_preview, cron_run_payload, run_daily_cron

    try:
        run = run_daily_cron(session)
        session.commit()
        return {
            "run": cron_run_payload(session, run),
            "preview": cron_queue_preview(session),
        }
    except Exception:
        session.commit()
        raise


@router.get("/me/preferences")
def get_preferences(user: User = Depends(get_current_user)):
    return {
        "neighborhood": neighborhood_counts(user),
        "llm_provider": llm_provider_for(user),
    }


@router.patch("/me/preferences")
def patch_preferences(
    body: PreferencesBody,
    user: User = Depends(get_current_user),
    session: Session = Depends(get_session),
):
    prefs = user.preferences
    if body.neighborhood is not None:
        prefs = merge_neighborhood_prefs(prefs, body.neighborhood)
    if body.llm_provider is not None:
        prefs = merge_llm_provider_pref(prefs, body.llm_provider)
    user.preferences = prefs
    session.add(user)
    session.commit()
    session.refresh(user)
    return {
        "neighborhood": neighborhood_counts(user),
        "llm_provider": llm_provider_for(user),
    }


@router.get("/jobs")
def list_jobs(
    state: str = "queued,running",
    user: User = Depends(get_current_user),
    session: Session = Depends(get_session),
):
    states = {part.strip() for part in state.split(",") if part.strip()}
    if not states:
        states = {"queued", "running"}
    return {"jobs": list_watched_jobs(session, user_id=user.id, states=states)}


@router.get("/knowledge/nodes/{node_id}/jobs")
def list_node_jobs(
    node_id: UUID,
    user: User = Depends(get_current_user),
    session: Session = Depends(get_session),
):
    """Active generate jobs for a node (any user); caller becomes a watcher."""
    node = session.get(KnowledgeNode, node_id)
    if node is None:
        raise not_found("Topic not found")
    jobs = list_and_watch_node_jobs(
        session,
        user_id=user.id,
        node_id=node_id,
        title=node.name,
    )
    session.commit()
    return {"jobs": jobs}


@router.get("/jobs/{job_id}")
def get_job(job_id: UUID, user: User = Depends(get_current_user), session: Session = Depends(get_session)):
    job = session.get(GenerationJob, job_id)
    if job is None:
        raise not_found("Job not found")
    if (
        job.user_id != user.id
        and not user.is_admin
        and not user_watches_job(session, job_id=job.id, user_id=user.id)
    ):
        raise forbidden()
    focus_id = (job.payload or {}).get("focus_id")
    return {
        "id": str(job.id),
        "type": job.type,
        "state": job.state,
        "progress": job.progress,
        "result": job.result,
        "focus_node_id": str(focus_id) if focus_id else None,
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
    payload, status = focus_or_enqueue(
        session,
        user=user,
        topic=body.topic,
        node_id=body.node_id,
        expand=body.expand,
    )
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


@router.get("/knowledge/nodes/{node_id}/content")
def get_knowledge_node_content(
    node_id: UUID,
    user: User = Depends(get_current_user),
    session: Session = Depends(get_session),
):
    return content_for_node(session, node_id, user_id=user.id)


@router.post("/knowledge/nodes/{node_id}/content")
def post_knowledge_node_content(
    node_id: UUID,
    body: KnowledgeContentBody,
    response: Response,
    user: User = Depends(get_current_user),
    session: Session = Depends(get_session),
):
    payload, status = content_or_expand(
        session,
        user=user,
        node_id=node_id,
        expand=body.expand,
        new_pack=body.new_pack,
    )
    session.commit()
    response.status_code = status
    return payload


@router.delete("/admin/knowledge/nodes/{node_id}/packs/{pack_index}")
def admin_delete_pack(
    node_id: UUID,
    pack_index: int,
    user: User = Depends(get_current_user),
    session: Session = Depends(get_session),
):
    """Admin: delete a shared pack, its bits, related events, and Leitner rows."""
    if not user.is_admin:
        raise forbidden()
    from app.features.content.admin_delete import delete_pack

    payload = delete_pack(session, node_id=node_id, pack_index=pack_index)
    session.commit()
    return payload


@router.delete("/admin/knowledge/nodes/{node_id}/packs/{pack_index}/bits/{kind}")
def admin_delete_pack_bit(
    node_id: UUID,
    pack_index: int,
    kind: str,
    confirm_last_pack: bool = False,
    user: User = Depends(get_current_user),
    session: Session = Depends(get_session),
):
    """Admin: delete one quiz bit (+ events). Last quiz requires confirm_last_pack=true."""
    if not user.is_admin:
        raise forbidden()
    from app.features.content.admin_delete import delete_check_bit

    payload = delete_check_bit(
        session,
        node_id=node_id,
        pack_index=pack_index,
        kind=kind,
        confirm_last_pack=confirm_last_pack,
    )
    session.commit()
    return payload


@router.get("/knowledge/nodes/{node_id}/image/file")
def get_knowledge_node_image_file(
    node_id: UUID,
    variant: str = "full",
    user: User = Depends(get_current_user),
    session: Session = Depends(get_session),
):
    _ = user
    choice = (variant or "full").strip().lower()
    if choice not in {"full", "thumb"}:
        raise AppError("VALIDATION_ERROR", "variant must be full or thumb", 422)
    payload, media_type = image_bytes_for_node(session, node_id, variant=choice)
    session.commit()
    return RawResponse(content=payload, media_type=media_type)


@router.get("/knowledge/nodes/{node_id}/image")
def get_knowledge_node_image(
    node_id: UUID,
    user: User = Depends(get_current_user),
    session: Session = Depends(get_session),
):
    _ = user
    return image_for_node(session, node_id)


@router.post("/knowledge/nodes/{node_id}/image")
def post_knowledge_node_image(
    node_id: UUID,
    body: KnowledgeImageBody,
    response: Response,
    user: User = Depends(get_current_user),
    session: Session = Depends(get_session),
):
    payload, status = image_or_generate(
        session,
        user=user,
        node_id=node_id,
        generate=body.generate,
        regenerate=body.regenerate,
    )
    session.commit()
    response.status_code = status
    return payload


@router.put("/knowledge/nodes/{node_id}/image")
async def put_knowledge_node_image(
    node_id: UUID,
    file: UploadFile = File(...),
    user: User = Depends(get_current_user),
    session: Session = Depends(get_session),
):
    _ = user
    raw = await file.read()
    payload = upload_node_image(session, node_id, raw=raw, content_type=file.content_type)
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
        "is_admin": bool(user.is_admin),
        "preferences": {"neighborhood": neighborhood_counts(user)},
    }
