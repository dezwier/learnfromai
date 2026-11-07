from __future__ import annotations

from uuid import UUID, uuid4

from fastapi import APIRouter, Depends, Header, Response
from pydantic import BaseModel, Field
from sqlmodel import Session, select

from app.core.db import get_session
from app.core.errors import forbidden, not_found
from app.core.security import get_current_user
from app.core.time import utcnow
from app.features.accounts.firebase_auth import exchange_firebase_token
from app.features.accounts.models import User
from app.features.goals_trajectories.models import LearningGoal
from app.features.goals_trajectories.service import (
    apply_diagnostic,
    create_goal,
    diagnostic_questions,
    latest_trajectory,
    recommendation,
    replan,
    require_goal,
    serialize_trajectory,
)
from app.features.graph_evolution.models import MigrationRun
from app.features.graph_evolution.service import accept_private, preview, publish_shared
from app.features.knowledge_graph.domain import ConceptNode, ObjectiveNode, ReleaseSnapshot
from app.features.knowledge_graph.models import Graph, GraphRelease
from app.features.knowledge_graph.service import (
    assert_can_edit,
    assert_can_read,
    build_tree,
    concept_detail,
    get_graph,
    list_releases,
    load_snapshot,
    publish_snapshot,
    release_diff,
    slugify,
)
from app.features.learning_content.service import public_activity
from app.features.learning_sessions.service import (
    complete_session,
    next_activity,
    require_session,
    start_session,
    submit_attempt,
)
from app.features.mastery.models import LearnerObjectiveState, MasteryEvidence
from app.features.mastery.service import concept_rollup
from app.features.platform.jobs import enqueue
from app.features.platform.llm import assert_user_quota
from app.features.platform.models import GenerationJob
from app.features.retention.models import ReviewEvent, ReviewItem
from app.features.retention.service import due_items, schedule_review

router = APIRouter()


class FirebaseBody(BaseModel):
    id_token: str


class GraphBody(BaseModel):
    title: str
    slug: str | None = None
    visibility: str = "private"


class RollbackBody(BaseModel):
    source_release_id: UUID
    base_release_id: UUID


class GoalBody(BaseModel):
    topic: str
    purpose: str = ""
    target_depth: str = "professional"
    minutes_per_week: int = 180
    language: str = "en"


class GoalPatch(BaseModel):
    title: str | None = None
    purpose: str | None = None
    target_depth: str | None = None
    minutes_per_week: int | None = None
    status: str | None = None


class DiagnosticBody(BaseModel):
    answers: list[dict] | None = None


class ExpansionBody(BaseModel):
    base_release_id: UUID
    parent_concept_id: UUID
    instruction: str
    max_depth: int = 2
    max_new_concepts: int = 12
    visibility: str = "private"


class SessionBody(BaseModel):
    goal_id: UUID
    concept_id: UUID | None = None


class AttemptBody(BaseModel):
    activity_id: UUID
    answer: dict = Field(default_factory=dict)
    client_submitted_at: str | None = None


class ReviewBody(BaseModel):
    answer: dict = Field(default_factory=dict)
    rating: str | None = None


class UpgradeBody(BaseModel):
    to_release_id: UUID


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


@router.post("/graphs", status_code=201)
def create_graph(body: GraphBody, user: User = Depends(get_current_user), session: Session = Depends(get_session)):
    graph = Graph(title=body.title, slug=body.slug or f"{str(user.id)[:8]}-{slugify(body.title)}", visibility="private", owner_user_id=user.id)
    session.add(graph)
    session.flush()
    concept_id = uuid4()
    objective_id = uuid4()
    snapshot = ReleaseSnapshot(
        concepts=[
            ConceptNode(
                concept_id=concept_id,
                title=body.title,
                summary=f"Starting map for {body.title}.",
                objectives=[ObjectiveNode(objective_id=objective_id, statement=f"Explain {body.title}", cognitive_dimension="understanding")],
            )
        ],
        edges=[],
    )
    release = publish_snapshot(session, graph_id=graph.id, base_release_id=None, snapshot=snapshot, actor_user_id=user.id)
    session.commit()
    return {"graph_id": str(graph.id), "release_id": str(release.id), "version": release.version}


@router.get("/graphs/{graph_id}/tree")
def graph_tree(
    graph_id: UUID,
    release_id: UUID | None = None,
    parent_concept_id: UUID | None = None,
    user: User = Depends(get_current_user),
    session: Session = Depends(get_session),
):
    graph = get_graph(session, graph_id)
    assert_can_read(graph, user)
    chosen = release_id or graph.active_release_id
    if chosen is None:
        raise not_found("Graph has no release")
    snapshot = load_snapshot(session, chosen)
    release = session.get(GraphRelease, chosen)
    tree = build_tree(snapshot, _mastery_by_concept(session, user.id, snapshot))
    if parent_concept_id is not None:
        tree = _find_children(tree, str(parent_concept_id))
    return {
        "graph_id": str(graph.id),
        "release_id": str(chosen),
        "version": release.version if release else None,
        "checksum": release.checksum if release else None,
        "nodes": tree,
    }


@router.get("/graphs/{graph_id}/concepts/{concept_id}")
def get_concept(
    graph_id: UUID,
    concept_id: UUID,
    release_id: UUID | None = None,
    user: User = Depends(get_current_user),
    session: Session = Depends(get_session),
):
    graph = get_graph(session, graph_id)
    assert_can_read(graph, user)
    chosen = release_id or graph.active_release_id
    if chosen is None:
        raise not_found("Graph has no release")
    return concept_detail(load_snapshot(session, chosen), concept_id) | {"release_id": str(chosen)}


@router.get("/graphs/{graph_id}/releases")
def releases(graph_id: UUID, user: User = Depends(get_current_user), session: Session = Depends(get_session)):
    graph = get_graph(session, graph_id)
    assert_can_read(graph, user)
    rows = list_releases(session, graph_id)
    return {
        "releases": [
            {
                "id": str(row.id),
                "version": row.version,
                "checksum": row.checksum,
                "parent_release_id": str(row.parent_release_id) if row.parent_release_id else None,
                "overlay_id": str(row.overlay_id) if row.overlay_id else None,
                "published_at": row.published_at.isoformat(),
            }
            for row in rows
        ]
    }


@router.get("/graphs/{graph_id}/diff")
def diff(graph_id: UUID, from_release: UUID, to_release: UUID, user: User = Depends(get_current_user), session: Session = Depends(get_session)):
    graph = get_graph(session, graph_id)
    assert_can_read(graph, user)
    return release_diff(session, from_release, to_release)


@router.post("/graphs/{graph_id}/rollback", status_code=201)
def rollback(graph_id: UUID, body: RollbackBody, user: User = Depends(get_current_user), session: Session = Depends(get_session)):
    graph = get_graph(session, graph_id)
    assert_can_edit(graph, user)
    snapshot = load_snapshot(session, body.source_release_id)
    release = publish_snapshot(
        session,
        graph_id=graph.id,
        base_release_id=body.base_release_id,
        snapshot=snapshot,
        actor_user_id=user.id,
    )
    session.commit()
    return {"release_id": str(release.id), "version": release.version, "checksum": release.checksum}


@router.post("/graphs/{graph_id}/expansions", status_code=202)
def expand(graph_id: UUID, body: ExpansionBody, user: User = Depends(get_current_user), session: Session = Depends(get_session)):
    graph = get_graph(session, graph_id)
    assert_can_read(graph, user)
    assert_user_quota(session, user.id)
    job = enqueue(
        session,
        job_type="expand_graph",
        user_id=user.id,
        idempotency_key=f"expand:{graph_id}:{body.base_release_id}:{body.parent_concept_id}:{body.instruction}",
        payload={
            "graph_id": str(graph_id),
            "base_release_id": str(body.base_release_id),
            "parent_concept_id": str(body.parent_concept_id),
            "instruction": body.instruction,
            "max_depth": body.max_depth,
            "max_new_concepts": min(body.max_new_concepts, 12),
            "visibility": body.visibility,
        },
    )
    session.commit()
    return {"job_id": str(job.id), "proposal_id": None, "status": "generating"}


@router.get("/graphs/{graph_id}/proposals/{proposal_id}")
def get_proposal(graph_id: UUID, proposal_id: UUID, user: User = Depends(get_current_user), session: Session = Depends(get_session)):
    from app.features.graph_evolution.models import GraphChangeProposal

    graph = get_graph(session, graph_id)
    assert_can_read(graph, user)
    proposal = session.get(GraphChangeProposal, proposal_id)
    if proposal is None or proposal.graph_id != graph_id:
        raise not_found("Proposal not found")
    if proposal.actor_user_id and proposal.actor_user_id != user.id and not user.is_admin:
        raise forbidden()
    return {
        "id": str(proposal.id),
        "status": proposal.status,
        "risk_class": proposal.risk_class,
        "base_release_id": str(proposal.base_release_id),
        "diff": proposal.diff,
        "validation": proposal.validation,
        "impact_summary": proposal.impact_summary,
        "result_release_id": str(proposal.result_release_id) if proposal.result_release_id else None,
    }


@router.post("/graphs/{graph_id}/proposals/{proposal_id}/accept-private")
def accept(graph_id: UUID, proposal_id: UUID, goal_id: UUID | None = None, user: User = Depends(get_current_user), session: Session = Depends(get_session)):
    result = accept_private(session, user, graph_id, proposal_id, goal_id)
    session.commit()
    return result


@router.post("/graphs/{graph_id}/proposals/{proposal_id}/publish")
def publish(graph_id: UUID, proposal_id: UUID, user: User = Depends(get_current_user), session: Session = Depends(get_session)):
    release = publish_shared(session, user, graph_id, proposal_id)
    session.commit()
    return {"release_id": str(release.id), "version": release.version}


@router.get("/graphs/{graph_id}/migration-preview")
def migration_preview(
    graph_id: UUID,
    proposal_id: UUID,
    goal_id: UUID | None = None,
    user: User = Depends(get_current_user),
    session: Session = Depends(get_session),
):
    payload = preview(session, user, graph_id, proposal_id, goal_id)
    session.commit()
    return payload


@router.post("/graphs/{graph_id}/freshness-checks", status_code=202)
def freshness(graph_id: UUID, user: User = Depends(get_current_user), session: Session = Depends(get_session)):
    if not user.is_admin:
        raise forbidden("Freshness checks are limited to admins")
    job = enqueue(session, job_type="freshness_check", user_id=user.id, payload={"graph_id": str(graph_id)})
    session.commit()
    return {"job_id": str(job.id), "status": "queued"}


@router.get("/migrations/{migration_id}")
def get_migration(migration_id: UUID, user: User = Depends(get_current_user), session: Session = Depends(get_session)):
    row = session.get(MigrationRun, migration_id)
    if row is None:
        raise not_found("Migration not found")
    if row.user_id != user.id and not user.is_admin:
        raise forbidden()
    return {
        "id": str(row.id),
        "status": row.status,
        "from_release_id": str(row.from_release_id),
        "to_release_id": str(row.to_release_id),
        "summary": row.summary,
        "completed_at": row.completed_at.isoformat() if row.completed_at else None,
    }


@router.post("/goals", status_code=202)
def post_goal(body: GoalBody, user: User = Depends(get_current_user), session: Session = Depends(get_session)):
    goal = create_goal(
        session,
        user,
        topic=body.topic,
        purpose=body.purpose,
        target_depth=body.target_depth,
        minutes_per_week=body.minutes_per_week,
        language=body.language,
    )
    job = enqueue(
        session,
        job_type="prepare_goal",
        user_id=user.id,
        idempotency_key=f"goal:{goal.id}",
        payload={"goal_id": str(goal.id)},
    )
    session.commit()
    graph = None
    return {"goal_id": str(goal.id), "status": goal.status, "job_id": str(job.id), "graph_id": graph, "graph_release_id": None}


@router.get("/goals")
def list_goals(user: User = Depends(get_current_user), session: Session = Depends(get_session)):
    rows = session.exec(
        select(LearningGoal)
        .where(LearningGoal.user_id == user.id, LearningGoal.status != "deleted")
        .order_by(LearningGoal.created_at.desc())
    ).all()
    return {"goals": [_goal_payload(session, row) for row in rows]}


@router.patch("/goals/{goal_id}")
def patch_goal(goal_id: UUID, body: GoalPatch, user: User = Depends(get_current_user), session: Session = Depends(get_session)):
    goal = require_goal(session, user, goal_id)
    if body.title is not None and body.title.strip():
        goal.title = body.title.strip()
    if body.purpose is not None:
        goal.purpose = body.purpose
    if body.target_depth is not None:
        goal.target_depth = body.target_depth
    if body.minutes_per_week is not None:
        goal.time_budget_minutes_week = body.minutes_per_week
    if body.status is not None:
        goal.status = body.status
    session.add(goal)
    replan(session, goal, "goal_edited")
    session.commit()
    return _goal_payload(session, goal)


@router.delete("/goals/{goal_id}")
def delete_goal(goal_id: UUID, user: User = Depends(get_current_user), session: Session = Depends(get_session)):
    goal = require_goal(session, user, goal_id)
    goal.status = "deleted"
    session.add(goal)
    session.commit()
    return {"id": str(goal.id), "status": goal.status}


@router.post("/goals/{goal_id}/diagnostic")
def diagnostic(goal_id: UUID, body: DiagnosticBody, user: User = Depends(get_current_user), session: Session = Depends(get_session)):
    goal = require_goal(session, user, goal_id)
    if body.answers is None:
        return {"status": goal.status, "questions": diagnostic_questions(session, goal)}
    apply_diagnostic(session, goal, body.answers)
    session.commit()
    trajectory = latest_trajectory(session, goal.id)
    return {"status": goal.status, "trajectory_version": trajectory.version if trajectory else None}


@router.get("/goals/{goal_id}/trajectory")
def get_trajectory(goal_id: UUID, user: User = Depends(get_current_user), session: Session = Depends(get_session)):
    goal = require_goal(session, user, goal_id)
    trajectory = latest_trajectory(session, goal.id)
    if trajectory is None:
        raise not_found("No trajectory yet")
    return serialize_trajectory(session, trajectory)


@router.post("/goals/{goal_id}/trajectory/replan")
def post_replan(goal_id: UUID, user: User = Depends(get_current_user), session: Session = Depends(get_session)):
    goal = require_goal(session, user, goal_id)
    trajectory = replan(session, goal, "manual")
    session.commit()
    if trajectory is None:
        raise not_found("Nothing to plan")
    return serialize_trajectory(session, trajectory)


@router.get("/goals/{goal_id}/recommendation")
def get_recommendation(goal_id: UUID, user: User = Depends(get_current_user), session: Session = Depends(get_session)):
    goal = require_goal(session, user, goal_id)
    return recommendation(session, goal)


@router.post("/goals/{goal_id}/upgrade-graph")
def upgrade(goal_id: UUID, body: UpgradeBody, user: User = Depends(get_current_user), session: Session = Depends(get_session)):
    from app.features.goals_trajectories.service import goal_link
    from app.features.graph_evolution.service import run_learner_migration

    goal = require_goal(session, user, goal_id)
    link = goal_link(session, goal.id)
    if link is None or link.release_id is None:
        raise not_found("Goal has no release")
    if link.release_id == body.to_release_id:
        return {"status": "succeeded", "release_id": str(link.release_id)}
    migration = run_learner_migration(
        session,
        user_id=user.id,
        from_release_id=link.release_id,
        to_release_id=body.to_release_id,
        proposal_id=None,
        goal_id=goal.id,
    )
    return {"migration_id": str(migration.id), "status": migration.status}


@router.get("/goals/{goal_id}/graph-changes")
def graph_changes(goal_id: UUID, user: User = Depends(get_current_user), session: Session = Depends(get_session)):
    goal = require_goal(session, user, goal_id)
    rows = session.exec(select(MigrationRun).where(MigrationRun.user_id == user.id, MigrationRun.goal_id == goal.id)).all()
    return {
        "migrations": [
            {
                "id": str(row.id),
                "status": row.status,
                "from_release_id": str(row.from_release_id),
                "to_release_id": str(row.to_release_id),
                "summary": row.summary,
            }
            for row in rows
        ]
    }


@router.get("/workspace/graph")
def workspace(
    trajectory_id: UUID | None = None,
    user: User = Depends(get_current_user),
    session: Session = Depends(get_session),
):
    from app.features.knowledge_graph.workspace import workspace_graph

    return workspace_graph(session, user, trajectory_id)


@router.post("/learning-sessions", status_code=201)
def open_session(body: SessionBody, user: User = Depends(get_current_user), session: Session = Depends(get_session)):
    row = start_session(session, user, body.goal_id, body.concept_id)
    session.commit()
    return {"session_id": str(row.id), "trajectory_id": str(row.trajectory_id), "release_id": str(row.release_id), "status": row.status}


@router.get("/learning-sessions/{session_id}/next")
def session_next(session_id: UUID, response: Response, user: User = Depends(get_current_user), session: Session = Depends(get_session)):
    row = require_session(session, user, session_id)
    payload = next_activity(session, user, row)
    session.commit()
    if payload["status"] == "generating":
        response.status_code = 202
    return payload


@router.post("/learning-sessions/{session_id}/attempts")
def post_attempt(
    session_id: UUID,
    body: AttemptBody,
    response: Response,
    user: User = Depends(get_current_user),
    session: Session = Depends(get_session),
    idempotency_key: str | None = Header(default=None, alias="Idempotency-Key"),
):
    row = require_session(session, user, session_id)
    payload, status = submit_attempt(
        session,
        user,
        row,
        activity_id=body.activity_id,
        answer=body.answer,
        idempotency_key=idempotency_key,
    )
    session.commit()
    response.status_code = status
    return payload


@router.post("/learning-sessions/{session_id}/complete")
def close_session(session_id: UUID, user: User = Depends(get_current_user), session: Session = Depends(get_session)):
    row = require_session(session, user, session_id)
    complete_session(session, user, row)
    session.commit()
    return {"session_id": str(row.id), "status": row.status}


@router.post("/activities/generate", status_code=202)
def generate(body: dict, user: User = Depends(get_current_user), session: Session = Depends(get_session)):
    assert_user_quota(session, user.id)
    job = enqueue(session, job_type="generate_activity", user_id=user.id, payload=body)
    session.commit()
    return {"job_id": str(job.id), "status": "queued"}


@router.get("/activities/{activity_id}")
def get_activity(activity_id: UUID, user: User = Depends(get_current_user), session: Session = Depends(get_session)):
    from app.features.learning_content.models import LearningActivity

    activity = session.get(LearningActivity, activity_id)
    if activity is None:
        raise not_found("Activity not found")
    _ = user
    return public_activity(session, activity)


@router.get("/reviews/due")
def reviews_due(limit: int = 20, user: User = Depends(get_current_user), session: Session = Depends(get_session)):
    items = due_items(session, user.id, limit)
    payload = []
    for item in items:
        prompt = _review_prompt(session, item)
        payload.append(
            {
                "id": str(item.id),
                "concept_id": str(item.concept_id),
                "objective_id": str(item.objective_id),
                "due_at": item.due_at.isoformat(),
                "status": "overdue" if item.due_at < utcnow() else "due",
                "prompt": prompt,
            }
        )
    return {"items": payload}


@router.post("/reviews/{review_item_id}/submit")
def submit_review(
    review_item_id: UUID,
    body: ReviewBody,
    user: User = Depends(get_current_user),
    session: Session = Depends(get_session),
    idempotency_key: str | None = Header(default=None, alias="Idempotency-Key"),
):
    item = session.get(ReviewItem, review_item_id)
    if item is None or item.user_id != user.id:
        raise not_found("Review item not found")
    if idempotency_key:
        prior = session.exec(select(ReviewEvent).where(ReviewEvent.review_item_id == item.id)).all()
        # Idempotency is enforced by a matching stored answer hash on the latest event note via attempts.
        _ = prior
    from app.features.learning_content.models import LearningActivity
    from app.features.learning_sessions.grading import grade_deterministic
    from app.features.learning_sessions.models import AssessmentAttempt
    from app.features.mastery.service import add_evidence

    activity = session.get(LearningActivity, item.activity_template_id) if item.activity_template_id else None
    if activity is None:
        raise not_found("Review has no activity")
    if idempotency_key:
        existing = session.exec(
            select(AssessmentAttempt).where(AssessmentAttempt.user_id == user.id, AssessmentAttempt.idempotency_key == idempotency_key)
        ).first()
        if existing is not None:
            return {"attempt_id": str(existing.id), "grading_status": "graded", "due_at": item.due_at.isoformat()}
    graded = grade_deterministic(activity.kind, activity.body, activity.rubric, body.answer)
    score = graded.score if graded else 0.0
    method = graded.method if graded else "keyword"
    attempt = AssessmentAttempt(
        user_id=user.id,
        session_id=None,
        activity_id=activity.id,
        concept_revision_id=activity.concept_revision_id,
        response=body.answer,
        score=score,
        rubric_results={"criterion_results": graded.criterion_results if graded else []},
        grading_method=method,
        grader_version=activity.prompt_version,
        idempotency_key=idempotency_key,
        confidence=1.0,
    )
    session.add(attempt)
    session.flush()
    add_evidence(
        session,
        user_id=user.id,
        objective_id=item.objective_id,
        objective_revision_id=item.objective_revision_id,
        concept_id=item.concept_id,
        concept_revision_id=activity.concept_revision_id,
        dimension=graded.dimension if graded else "recall",
        score=score,
        weight=1.0,
        method=method,
        attempt_id=attempt.id,
    )
    updated = schedule_review(
        session,
        user_id=user.id,
        concept_id=item.concept_id,
        objective_id=item.objective_id,
        objective_revision_id=item.objective_revision_id,
        activity_id=activity.id,
        score=score,
        rating_override=body.rating,
        attempt_id=attempt.id,
    )
    session.commit()
    return {
        "attempt_id": str(attempt.id),
        "grading_status": "graded",
        "feedback": {"score": score, "rating": body.rating},
        "due_at": updated.due_at.isoformat(),
    }


@router.get("/reviews/stats")
def review_stats(user: User = Depends(get_current_user), session: Session = Depends(get_session)):
    due = due_items(session, user.id, 100)
    events = session.exec(select(ReviewEvent).join(ReviewItem).where(ReviewItem.user_id == user.id)).all()
    return {"due": len(due), "overdue": len(due), "events": len(events), "timezone": user.timezone}


@router.get("/mastery/overview")
def mastery_overview(goal_id: UUID, user: User = Depends(get_current_user), session: Session = Depends(get_session)):
    goal = require_goal(session, user, goal_id)
    from app.features.goals_trajectories.service import goal_link

    link = goal_link(session, goal.id)
    if link is None or link.release_id is None:
        return {"goal_id": str(goal.id), "concepts": [], "due_reviews": 0}
    snapshot = load_snapshot(session, link.release_id)
    concepts = []
    for concept in snapshot.concepts:
        rollup = concept_rollup(session, user.id, concept.concept_id, [item.objective_id for item in concept.objectives])
        concepts.append({"concept_id": str(concept.concept_id), "title": concept.title, **rollup})
    return {"goal_id": str(goal.id), "concepts": concepts, "due_reviews": len(due_items(session, user.id, 100))}


@router.get("/mastery/concepts/{concept_id}")
def mastery_concept(concept_id: UUID, user: User = Depends(get_current_user), session: Session = Depends(get_session)):
    states = session.exec(
        select(LearnerObjectiveState).where(LearnerObjectiveState.user_id == user.id, LearnerObjectiveState.concept_id == concept_id)
    ).all()
    return {
        "concept_id": str(concept_id),
        "objectives": [
            {
                "objective_id": str(state.objective_id),
                "status": state.status,
                "estimate": state.mastery_estimate,
                "confidence": state.confidence,
                "evidence_count": state.evidence_count,
                "dimensions": state.dimensions,
            }
            for state in states
        ],
    }


@router.get("/mastery/evidence")
def mastery_evidence(concept_id: UUID | None = None, user: User = Depends(get_current_user), session: Session = Depends(get_session)):
    query = select(MasteryEvidence).where(MasteryEvidence.user_id == user.id)
    rows = list(session.exec(query).all())
    if concept_id is not None:
        states = session.exec(
            select(LearnerObjectiveState.objective_id).where(
                LearnerObjectiveState.user_id == user.id,
                LearnerObjectiveState.concept_id == concept_id,
            )
        ).all()
        allowed = set(states)
        rows = [row for row in rows if row.objective_id in allowed]
    return {
        "evidence": [
            {
                "id": str(row.id),
                "objective_id": str(row.objective_id),
                "objective_revision_id": str(row.objective_revision_id),
                "concept_revision_id": str(row.concept_revision_id),
                "attempt_id": str(row.attempt_id) if row.attempt_id else None,
                "score": row.observed_score,
                "dimension": row.dimension,
                "grading_method": row.grading_method,
                "migration_origin_id": str(row.migration_origin_id) if row.migration_origin_id else None,
                "created_at": row.created_at.isoformat(),
            }
            for row in rows
        ]
    }


@router.get("/mastery/gaps")
def mastery_gaps(goal_id: UUID, user: User = Depends(get_current_user), session: Session = Depends(get_session)):
    goal = require_goal(session, user, goal_id)
    payload = recommendation(session, goal)
    return {"goal_id": str(goal.id), "next": payload.get("step"), "note": "Gaps are objectives that are not demonstrated."}


def _user_payload(user: User) -> dict:
    return {
        "id": str(user.id),
        "firebase_uid": user.firebase_uid,
        "email": user.email,
        "display_name": user.display_name,
        "timezone": user.timezone,
        "is_admin": user.is_admin,
    }


def _goal_payload(session: Session, goal: LearningGoal) -> dict:
    from app.features.goals_trajectories.service import (
        goal_link,
        latest_trajectory,
        serialize_trajectory,
    )

    link = goal_link(session, goal.id)
    trajectory = latest_trajectory(session, goal.id)
    sequence: list[str] = []
    trajectory_id = None
    if trajectory is not None:
        payload = serialize_trajectory(session, trajectory)
        sequence = [
            step["concept_title"]
            for step in payload["steps"]
            if step.get("concept_title") and not str(step["concept_title"]).lower().endswith(" practice")
        ]
        trajectory_id = str(trajectory.id)
    return {
        "id": str(goal.id),
        "title": goal.title,
        "topic": goal.topic,
        "status": goal.status,
        "purpose": goal.purpose,
        "target_depth": goal.target_depth,
        "minutes_per_week": goal.time_budget_minutes_week,
        "graph_id": str(link.graph_id) if link else None,
        "release_id": str(link.release_id) if link and link.release_id else None,
        "trajectory_id": trajectory_id,
        "sequence": sequence,
    }


def _mastery_by_concept(session: Session, user_id: UUID, snapshot) -> dict:
    result = {}
    for concept in snapshot.concepts:
        rollup = concept_rollup(session, user_id, concept.concept_id, [item.objective_id for item in concept.objectives])
        result[concept.concept_id] = rollup["status"]
    return result


def _find_children(nodes: list[dict], concept_id: str) -> list[dict]:
    for node in nodes:
        if node["concept_id"] == concept_id:
            return node["children"]
        found = _find_children(node["children"], concept_id)
        if found:
            return found
    return []


def _review_prompt(session: Session, item: ReviewItem) -> str:
    from app.features.learning_content.models import LearningActivity

    if item.activity_template_id:
        activity = session.get(LearningActivity, item.activity_template_id)
        if activity is not None:
            body = dict(activity.body)
            body.pop("answer", None)
            return str(body.get("prompt") or body.get("explanation") or "Recall the idea")
    return "Recall the idea before revealing the answer."

