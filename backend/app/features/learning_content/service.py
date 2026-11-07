from __future__ import annotations

import hashlib
import json
from uuid import UUID

from sqlmodel import Session, select

from app.features.learning_content.models import ActivityObjective, LearningActivity
from app.features.platform.llm import PROMPT_ACTIVITY, get_provider, record_usage

ACTIVITY_KINDS = ("explain", "retrieval_short_answer", "multiple_choice", "apply", "teach_back")


def content_hash(
    *,
    concept_revision_id: UUID,
    objective_revision_ids: list[UUID],
    kind: str,
    language: str,
    difficulty: int,
    source_hash: str,
    band: str,
) -> str:
    payload = {
        "band": band,
        "concept_revision_id": str(concept_revision_id),
        "difficulty": difficulty,
        "kind": kind,
        "language": language,
        "objective_revision_ids": sorted(str(item) for item in objective_revision_ids),
        "prompt_version": PROMPT_ACTIVITY,
        "source_hash": source_hash,
    }
    raw = json.dumps(payload, separators=(",", ":"), sort_keys=True)
    return hashlib.sha256(raw.encode()).hexdigest()


def find_activity(session: Session, digest: str, kind: str) -> LearningActivity | None:
    return session.exec(
        select(LearningActivity).where(LearningActivity.content_hash == digest, LearningActivity.kind == kind)
    ).first()


def generate_activity(
    session: Session,
    *,
    user_id: UUID | None,
    job_id: UUID | None,
    concept_revision_id: UUID,
    concept_title: str,
    objectives: list[dict],
    kind: str,
    language: str = "en",
    difficulty: int = 1,
    source_hash: str = "none",
    band: str = "new",
) -> LearningActivity:
    revision_ids = [UUID(item["revision_id"]) for item in objectives]
    digest = content_hash(
        concept_revision_id=concept_revision_id,
        objective_revision_ids=revision_ids,
        kind=kind,
        language=language,
        difficulty=difficulty,
        source_hash=source_hash,
        band=band,
    )
    cached = find_activity(session, digest, kind)
    if cached is not None:
        return cached
    provider = get_provider()
    statement = objectives[0]["statement"]
    keyword = statement.split()[-1].strip(".").lower()
    generated, usage = provider.generate_activity(
        {
            "kind": kind,
            "statement": statement,
            "concept_title": concept_title,
            "keyword": keyword,
            "difficulty": difficulty,
            "language": language,
            "objective_ids": [item["id"] for item in objectives],
            "objective_revision_ids": [item["revision_id"] for item in objectives],
            "concept_revision_id": str(concept_revision_id),
        }
    )
    record_usage(session, user_id=user_id, job_id=job_id, task="generate_activity", provider=provider.name, usage=usage)
    body = generated.get("content") or {}
    rubric = generated.get("rubric") or {"mode": "keyword", "must_include": [keyword]}
    activity = LearningActivity(
        concept_revision_id=concept_revision_id,
        kind=kind,
        body=body,
        rubric=rubric,
        content_hash=digest,
        prompt_version=str(generated.get("prompt_version") or PROMPT_ACTIVITY),
        model=str(usage.get("model") or provider.name),
        review_status="generated",
        language=language,
        difficulty=difficulty,
    )
    session.add(activity)
    session.flush()
    for item in objectives:
        session.add(
            ActivityObjective(
                activity_id=activity.id,
                objective_id=UUID(item["id"]),
                objective_revision_id=UUID(item["revision_id"]),
            )
        )
    session.flush()
    return activity


def public_activity(session: Session, activity: LearningActivity) -> dict:
    links = session.exec(select(ActivityObjective).where(ActivityObjective.activity_id == activity.id)).all()
    body = dict(activity.body)
    secret = body.pop("answer", None)
    _ = secret
    rubric = activity.rubric or {}
    public_rubric = {
        "dimension": rubric.get("dimension"),
        "criteria": [{"id": item.get("id"), "prompt": item.get("prompt")} for item in rubric.get("criteria") or []],
    }
    return {
        "id": str(activity.id),
        "kind": activity.kind,
        "concept_revision_id": str(activity.concept_revision_id),
        "objective_ids": [str(link.objective_id) for link in links],
        "objective_revision_ids": [str(link.objective_revision_id) for link in links],
        "body": body,
        "rubric": public_rubric,
        "review_status": activity.review_status,
        "content_hash": activity.content_hash,
        "prompt_version": activity.prompt_version,
        "model": activity.model,
        "language": activity.language,
        "difficulty": activity.difficulty,
        "sources": body.get("sources") or [],
    }
