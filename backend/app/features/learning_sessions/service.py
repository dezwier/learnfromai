from __future__ import annotations

from uuid import UUID

from sqlmodel import Session, select

from app.core.config import get_settings
from app.core.errors import forbidden, not_found
from app.core.time import utcnow
from app.features.accounts.models import User
from app.features.goals_trajectories.models import TrajectoryStep
from app.features.goals_trajectories.service import latest_trajectory, replan, require_goal
from app.features.knowledge_graph.service import load_snapshot
from app.features.learning_content.models import ActivityObjective, LearningActivity
from app.features.learning_content.service import public_activity
from app.features.learning_sessions.grading import grade_deterministic
from app.features.learning_sessions.models import AssessmentAttempt, LearningSession
from app.features.mastery.service import add_evidence
from app.features.platform.llm import get_provider, record_usage
from app.features.retention.service import schedule_review


def start_session(session: Session, user: User, goal_id: UUID, concept_id: UUID | None = None) -> LearningSession:
    goal = require_goal(session, user, goal_id)
    trajectory = latest_trajectory(session, goal.id)
    if trajectory is None:
        trajectory = replan(session, goal, "session")
    if trajectory is None:
        raise not_found("No trajectory yet")
    from app.features.goals_trajectories.models import TrajectoryRelease

    pin = session.exec(select(TrajectoryRelease).where(TrajectoryRelease.trajectory_id == trajectory.id)).first()
    if pin is None:
        raise not_found("Trajectory has no release pin")
    rank = _rank_for_concept(session, trajectory.id, pin.release_id, concept_id)
    row = LearningSession(
        user_id=user.id,
        goal_id=goal.id,
        trajectory_id=trajectory.id,
        release_id=pin.release_id,
        status="active",
        activity_phase="explain",
        cursor_rank=rank,
    )
    session.add(row)
    session.flush()
    return row


def require_session(session: Session, user: User, session_id: UUID) -> LearningSession:
    row = session.get(LearningSession, session_id)
    if row is None:
        raise not_found("Session not found")
    if row.user_id != user.id:
        raise forbidden("Not your session")
    return row


def next_activity(session: Session, user: User, learning_session: LearningSession) -> dict:
    if learning_session.status != "active":
        return {"status": "complete", "activity": None, "job_id": None}
    step = _current_step(session, learning_session)
    if step is None:
        return {"status": "complete", "activity": None, "job_id": None}
    kind = "explain" if learning_session.activity_phase == "explain" else "retrieval_short_answer"
    snapshot = load_snapshot(session, learning_session.release_id)
    concept = snapshot.concept(step.concept_id)
    if concept is None:
        raise not_found("Pinned concept left the session release")
    objective = next(item for item in concept.objectives if item.objective_id == step.objective_id)
    from app.features.learning_content.service import content_hash, find_activity
    from app.features.platform.jobs import enqueue
    from app.features.platform.llm import PROMPT_ACTIVITY, assert_user_quota

    digest = content_hash(
        concept_revision_id=concept.revision_id,  # type: ignore[arg-type]
        objective_revision_ids=[objective.revision_id],  # type: ignore[list-item]
        kind=kind,
        language="en",
        difficulty=1,
        source_hash="none",
        band="new",
    )
    cached = find_activity(session, digest, kind)
    if cached is None:
        assert_user_quota(session, user.id)
        job = enqueue(
            session,
            job_type="generate_activity",
            user_id=user.id,
            idempotency_key=digest,
            payload={
                "concept_revision_id": str(concept.revision_id),
                "concept_title": concept.title,
                "kind": kind,
                "language": "en",
                "difficulty": 1,
                "source_hash": "none",
                "band": "new",
                "prompt_version": PROMPT_ACTIVITY,
                "objectives": [
                    {
                        "id": str(objective.objective_id),
                        "revision_id": str(objective.revision_id),
                        "statement": objective.statement,
                    }
                ],
            },
        )
        return {"status": "generating", "activity": None, "job_id": str(job.id), "step_rank": step.rank}
    return {"status": "ready", "activity": public_activity(session, cached), "job_id": None, "step_rank": step.rank}


def submit_attempt(
    session: Session,
    user: User,
    learning_session: LearningSession,
    *,
    activity_id: UUID,
    answer: dict,
    idempotency_key: str | None,
) -> tuple[dict, int]:
    if idempotency_key:
        existing = session.exec(
            select(AssessmentAttempt).where(
                AssessmentAttempt.user_id == user.id,
                AssessmentAttempt.idempotency_key == idempotency_key,
            )
        ).first()
        if existing is not None:
            return _attempt_payload(session, learning_session, existing), 200
    activity = session.get(LearningActivity, activity_id)
    if activity is None:
        raise not_found("Activity not found")
    links = list(session.exec(select(ActivityObjective).where(ActivityObjective.activity_id == activity.id)).all())
    if activity.kind == "explain":
        attempt = AssessmentAttempt(
            user_id=user.id,
            session_id=learning_session.id,
            activity_id=activity.id,
            concept_revision_id=activity.concept_revision_id,
            response=answer,
            score=None,
            rubric_results={"note": "Reading is not mastery evidence"},
            grading_method="reading",
            grader_version="none",
            idempotency_key=idempotency_key,
        )
        session.add(attempt)
        session.flush()
        learning_session.activity_phase = "assess"
        return _attempt_payload(session, learning_session, attempt, objectives_changed=0), 201

    graded = grade_deterministic(activity.kind, activity.body, activity.rubric, answer)
    if graded is None and get_settings().llm_provider != "fake":
        from app.features.platform.jobs import enqueue

        job = enqueue(
            session,
            job_type="grade_answer",
            user_id=user.id,
            idempotency_key=idempotency_key,
            payload={
                "activity_id": str(activity.id),
                "session_id": str(learning_session.id),
                "answer": answer,
                "user_id": str(user.id),
            },
        )
        return {"attempt_id": None, "grading_status": "pending", "job_id": str(job.id), "feedback": None, "mastery_update": {"objectives_changed": 0}, "trajectory_version": None}, 202
    if graded is None:
        provider = get_provider()
        generated, usage = provider.grade_open_answer(
            {
                "answer": answer,
                "rubric": activity.rubric,
                "must_include": (activity.rubric or {}).get("must_include") or [],
                "activity_id": str(activity.id),
            }
        )
        record_usage(
            session,
            user_id=user.id,
            job_id=None,
            task="grade_open_answer",
            provider=provider.name,
            usage=usage,
        )
        from app.features.learning_sessions.grading import GradeResult

        graded = GradeResult(
            score=float(generated.get("score") or 0),
            method="model",
            confidence=float(generated.get("confidence") or 0.4),
            criterion_results=list(generated.get("criterion_results") or []),
            next_hint=str(generated.get("next_hint") or ""),
            uncertain=bool(generated.get("uncertain")),
            dimension=(activity.rubric or {}).get("dimension") or "understanding",
        )
    attempt = AssessmentAttempt(
        user_id=user.id,
        session_id=learning_session.id,
        activity_id=activity.id,
        concept_revision_id=activity.concept_revision_id,
        response=answer,
        score=graded.score,
        rubric_results={"criterion_results": graded.criterion_results, "next_hint": graded.next_hint},
        confidence=graded.confidence,
        grading_method=graded.method,
        grader_version=activity.prompt_version,
        idempotency_key=idempotency_key,
    )
    session.add(attempt)
    session.flush()
    snapshot = load_snapshot(session, learning_session.release_id)
    changed = 0
    for link in links:
        concept = next(item for item in snapshot.concepts if any(obj.objective_id == link.objective_id for obj in item.objectives))
        add_evidence(
            session,
            user_id=user.id,
            objective_id=link.objective_id,
            objective_revision_id=link.objective_revision_id,
            concept_id=concept.concept_id,
            concept_revision_id=activity.concept_revision_id,
            dimension=graded.dimension,
            score=graded.score,
            weight=0.55 if graded.uncertain else 1.0,
            method=graded.method,
            attempt_id=attempt.id,
            uncertain=graded.uncertain,
        )
        schedule_review(
            session,
            user_id=user.id,
            concept_id=concept.concept_id,
            objective_id=link.objective_id,
            objective_revision_id=link.objective_revision_id,
            activity_id=activity.id,
            score=graded.score,
            rating_override=None,
            attempt_id=attempt.id,
        )
        changed += 1
    goal = require_goal(session, user, learning_session.goal_id)
    replan(session, goal, "assessment")
    _advance(session, learning_session)
    return _attempt_payload(session, learning_session, attempt, objectives_changed=changed), 201


def complete_session(session: Session, user: User, learning_session: LearningSession) -> LearningSession:
    learning_session.status = "complete"
    learning_session.ended_at = utcnow()
    session.add(learning_session)
    session.flush()
    return learning_session


def _rank_for_concept(session: Session, trajectory_id: UUID, release_id: UUID, concept_id: UUID | None) -> int:
    if concept_id is None:
        return 1
    step = session.exec(
        select(TrajectoryStep)
        .where(TrajectoryStep.trajectory_id == trajectory_id, TrajectoryStep.concept_id == concept_id)
        .order_by(TrajectoryStep.rank)
    ).first()
    if step is not None:
        return step.rank
    snapshot = load_snapshot(session, release_id)
    concept = snapshot.concept(concept_id)
    if concept is None or not concept.objectives:
        raise not_found("Concept is not in this goal")
    ranks = list(session.exec(select(TrajectoryStep.rank).where(TrajectoryStep.trajectory_id == trajectory_id)).all())
    rank = (max(ranks) if ranks else 0) + 1
    session.add(
        TrajectoryStep(
            trajectory_id=trajectory_id,
            concept_id=concept.concept_id,
            objective_id=concept.objectives[0].objective_id,
            step_type="learn",
            rank=rank,
            rationale="Opened from the graph",
            estimated_minutes=12,
        )
    )
    session.flush()
    return rank


def _current_step(session: Session, learning_session: LearningSession) -> TrajectoryStep | None:
    return session.exec(
        select(TrajectoryStep).where(
            TrajectoryStep.trajectory_id == learning_session.trajectory_id,
            TrajectoryStep.rank == learning_session.cursor_rank,
        )
    ).first()


def _advance(session: Session, learning_session: LearningSession) -> None:
    learning_session.cursor_rank += 1
    learning_session.activity_phase = "explain"
    nxt = _current_step(session, learning_session)
    if nxt is None:
        learning_session.status = "complete"
        learning_session.ended_at = utcnow()
    session.add(learning_session)
    session.flush()


def _attempt_payload(session: Session, learning_session: LearningSession, attempt: AssessmentAttempt, objectives_changed: int | None = None) -> dict:
    from app.features.goals_trajectories.models import Trajectory

    trajectory = session.get(Trajectory, learning_session.trajectory_id)
    if objectives_changed is None:
        objectives_changed = 0 if attempt.grading_method in {"reading", "pending"} else 1
    return {
        "attempt_id": str(attempt.id),
        "grading_status": "graded" if attempt.grading_method != "pending" else "pending",
        "feedback": {
            "score": attempt.score,
            "criterion_results": (attempt.rubric_results or {}).get("criterion_results") or [],
            "next_hint": (attempt.rubric_results or {}).get("next_hint") or (attempt.rubric_results or {}).get("note") or "",
            "uncertain": attempt.confidence is not None and attempt.confidence < 0.5,
        },
        "mastery_update": {"objectives_changed": objectives_changed},
        "trajectory_version": trajectory.version if trajectory else None,
    }
