from __future__ import annotations

from uuid import UUID, uuid4

from sqlmodel import Session, select

from app.core.config import get_settings
from app.core.errors import forbidden, not_found
from app.features.accounts.models import User
from app.features.goals_trajectories.models import (
    GoalGraph,
    LearningGoal,
    Trajectory,
    TrajectoryRelease,
    TrajectoryStep,
)
from app.features.goals_trajectories.planner import PlanCandidate, plan_trajectory, steps_signature
from app.features.knowledge_graph.domain import ReleaseSnapshot
from app.features.knowledge_graph.service import find_graph_for_topic, load_snapshot, slugify
from app.features.mastery.models import LearnerObjectiveState
from app.features.retention.models import ReviewItem


def create_goal(
    session: Session,
    user: User,
    *,
    topic: str,
    purpose: str,
    target_depth: str,
    minutes_per_week: int,
    language: str,
) -> LearningGoal:
    goal = LearningGoal(
        user_id=user.id,
        title=topic.strip(),
        topic=topic.strip(),
        purpose=purpose,
        language=language,
        target_depth=target_depth,
        time_budget_minutes_week=minutes_per_week,
        target_outcomes={"purpose": purpose, "depth": target_depth},
        status="preparing",
    )
    session.add(goal)
    session.flush()
    return goal


def require_goal(session: Session, user: User, goal_id: UUID) -> LearningGoal:
    goal = session.get(LearningGoal, goal_id)
    if goal is None:
        raise not_found("Goal not found")
    if goal.user_id != user.id:
        raise forbidden("Not your goal")
    return goal


def attach_graph(session: Session, goal: LearningGoal, graph_id: UUID, release_id: UUID, overlay_id: UUID | None = None) -> GoalGraph:
    link = session.get(GoalGraph, (goal.id, graph_id))
    if link is None:
        link = GoalGraph(goal_id=goal.id, graph_id=graph_id, release_id=release_id, overlay_id=overlay_id)
        session.add(link)
    else:
        link.release_id = release_id
        link.overlay_id = overlay_id
    session.flush()
    return link


def goal_link(session: Session, goal_id: UUID) -> GoalGraph | None:
    return session.exec(select(GoalGraph).where(GoalGraph.goal_id == goal_id)).first()


def active_session_pins(session: Session, goal_id: UUID) -> set[UUID]:
    from app.features.learning_sessions.models import LearningSession

    rows = session.exec(
        select(LearningSession.trajectory_id).where(
            LearningSession.goal_id == goal_id,
            LearningSession.status == "active",
        )
    ).all()
    return set(rows)


def focus_concepts(snapshot: ReleaseSnapshot, topic: str) -> list:
    """The topic node and the more specific nodes under it. That sequence is the trajectory."""
    from app.features.knowledge_graph.identity import is_placeholder_title, same_topic

    titles = {concept.title for concept in snapshot.concepts}
    root = next(
        (concept for concept in snapshot.concepts if same_topic(concept.canonical_key or concept.title, topic)),
        None,
    )
    if root is None:
        return [
            concept
            for concept in snapshot.concepts
            if not concept.title.lower().endswith(" practice") and not is_placeholder_title(concept.title, titles)
        ]
    children: dict[UUID, list[UUID]] = {}
    for edge in snapshot.edges:
        if edge.type == "contains":
            children.setdefault(edge.from_concept_id, []).append(edge.to_concept_id)
    ordered = []
    seen: set[UUID] = set()

    def walk(concept_id: UUID) -> None:
        if concept_id in seen:
            return
        seen.add(concept_id)
        concept = snapshot.concept(concept_id)
        if concept is None or concept.title.lower().endswith(" practice") or is_placeholder_title(concept.title, titles):
            return
        ordered.append(concept)
        for child in children.get(concept_id, []):
            walk(child)

    walk(root.concept_id)
    return ordered


def replan(session: Session, goal: LearningGoal, reason: str) -> Trajectory | None:
    link = goal_link(session, goal.id)
    if link is None or link.release_id is None:
        return None
    snapshot = load_snapshot(session, link.release_id)
    focus_ids = [str(item) for item in (goal.target_outcomes or {}).get("focus_concept_ids") or []]
    if focus_ids:
        by_id = {concept.concept_id: concept for concept in snapshot.concepts}
        ordered = [by_id[UUID(item)] for item in focus_ids if UUID(item) in by_id]
        steps = _sequence_steps(ordered)
    else:
        candidates = _candidates(session, goal, snapshot)
        review_slots = 2 if any(item.has_due_review for item in candidates) else 0
        learn_slots = max(2, min(5, goal.time_budget_minutes_week // 60 or 2))
        steps = plan_trajectory(candidates, review_slots=review_slots, learn_slots=learn_slots)
    latest = session.exec(
        select(Trajectory).where(Trajectory.goal_id == goal.id).order_by(Trajectory.version.desc())
    ).first()
    if latest is not None:
        existing = session.exec(select(TrajectoryStep).where(TrajectoryStep.trajectory_id == latest.id)).all()
        existing_sig = tuple(
            (step.concept_id, step.objective_id, step.step_type, step.rank)
            for step in sorted(existing, key=lambda item: item.rank)
        )
        if existing_sig == steps_signature(steps):
            return latest
    version = 1 if latest is None else latest.version + 1
    trajectory = Trajectory(
        goal_id=goal.id,
        version=version,
        planner_version=get_settings().planner_version,
        reason=reason,
    )
    session.add(trajectory)
    session.flush()
    session.add(TrajectoryRelease(trajectory_id=trajectory.id, graph_id=link.graph_id, release_id=link.release_id))
    for step in steps:
        session.add(
            TrajectoryStep(
                trajectory_id=trajectory.id,
                concept_id=step.concept_id,
                objective_id=step.objective_id,
                step_type=step.step_type,
                rank=step.rank,
                rationale=step.rationale,
                estimated_minutes=step.estimated_minutes,
            )
        )
    session.flush()
    return trajectory


def _sequence_steps(concepts: list):
    from app.features.goals_trajectories.planner import PlannedStep

    steps = []
    rank = 1
    for concept in concepts:
        if not concept.objectives:
            continue
        objective = concept.objectives[0]
        steps.append(
            PlannedStep(
                objective_id=objective.objective_id,
                concept_id=concept.concept_id,
                step_type="learn",
                rank=rank,
                rationale=f"Step {rank} on this path",
                estimated_minutes=12,
                score=1.0,
            )
        )
        rank += 1
    return steps


def diagnostic_questions(session: Session, goal: LearningGoal) -> list[dict]:
    link = goal_link(session, goal.id)
    if link is None or link.release_id is None:
        return []
    snapshot = load_snapshot(session, link.release_id)
    questions = []
    focus_ids = {str(item) for item in (goal.target_outcomes or {}).get("focus_concept_ids") or []}
    concepts = [concept for concept in snapshot.concepts if not focus_ids or str(concept.concept_id) in focus_ids]
    for concept in concepts:
        for objective in concept.objectives:
            questions.append(
                {
                    "objective_id": str(objective.objective_id),
                    "concept_id": str(concept.concept_id),
                    "concept_title": concept.title,
                    "statement": objective.statement,
                }
            )
    return questions[:6]


def apply_diagnostic(session: Session, goal: LearningGoal, answers: list[dict]) -> None:
    from app.features.mastery.service import add_evidence

    link = goal_link(session, goal.id)
    if link is None or link.release_id is None:
        raise not_found("Goal has no graph yet")
    snapshot = load_snapshot(session, link.release_id)
    lookup = {
        objective.objective_id: (concept, objective)
        for concept in snapshot.concepts
        for objective in concept.objectives
    }
    for answer in answers:
        objective_id = UUID(str(answer["objective_id"]))
        response = answer.get("response") or "unknown"
        if response == "unknown" or objective_id not in lookup:
            continue
        concept, objective = lookup[objective_id]
        score = {"know": 0.7, "partial": 0.4}.get(response, 0.0)
        add_evidence(
            session,
            user_id=goal.user_id,
            objective_id=objective.objective_id,
            objective_revision_id=objective.revision_id,  # type: ignore[arg-type]
            concept_id=concept.concept_id,
            concept_revision_id=concept.revision_id,  # type: ignore[arg-type]
            dimension="recall",
            score=score,
            weight=0.15,
            method="self_report",
            attempt_id=None,
        )
    goal.status = "active"
    replan(session, goal, "diagnostic")


def serialize_trajectory(session: Session, trajectory: Trajectory) -> dict:
    steps = session.exec(select(TrajectoryStep).where(TrajectoryStep.trajectory_id == trajectory.id)).all()
    releases = session.exec(select(TrajectoryRelease).where(TrajectoryRelease.trajectory_id == trajectory.id)).all()
    titles = {}
    if releases:
        snapshot = load_snapshot(session, releases[0].release_id)
        titles = {concept.concept_id: concept.title for concept in snapshot.concepts}
    return {
        "id": str(trajectory.id),
        "goal_id": str(trajectory.goal_id),
        "version": trajectory.version,
        "planner_version": trajectory.planner_version,
        "reason": trajectory.reason,
        "releases": [
            {"graph_id": str(item.graph_id), "release_id": str(item.release_id)} for item in releases
        ],
        "steps": [
            {
                "id": str(step.id),
                "concept_id": str(step.concept_id),
                "concept_title": titles.get(step.concept_id, ""),
                "objective_id": str(step.objective_id),
                "step_type": step.step_type,
                "rank": step.rank,
                "status": step.status,
                "rationale": step.rationale,
                "estimated_minutes": step.estimated_minutes,
            }
            for step in sorted(steps, key=lambda item: item.rank)
        ],
    }


def latest_trajectory(session: Session, goal_id: UUID) -> Trajectory | None:
    return session.exec(
        select(Trajectory).where(Trajectory.goal_id == goal_id).order_by(Trajectory.version.desc())
    ).first()


def recommendation(session: Session, goal: LearningGoal) -> dict:
    trajectory = latest_trajectory(session, goal.id)
    if trajectory is None:
        return {"step": None, "trajectory_version": None}
    payload = serialize_trajectory(session, trajectory)
    learn = [step for step in payload["steps"] if step["step_type"] == "learn"] or payload["steps"]
    return {"step": learn[0] if learn else None, "trajectory_version": trajectory.version}


def _candidates(session: Session, goal: LearningGoal, snapshot: ReleaseSnapshot) -> list[PlanCandidate]:
    prereq_by_concept: dict[UUID, list[UUID]] = {concept.concept_id: [] for concept in snapshot.concepts}
    for edge in snapshot.edges:
        if edge.type == "prerequisite":
            prereq_by_concept.setdefault(edge.to_concept_id, []).append(edge.from_concept_id)
    objectives_by_concept = {concept.concept_id: concept.objectives for concept in snapshot.concepts}
    from app.core.time import utcnow

    due_now = set(
        row.objective_id
        for row in session.exec(
            select(ReviewItem).where(ReviewItem.user_id == goal.user_id, ReviewItem.status == "active")
        ).all()
        if row.due_at <= utcnow()
    )
    candidates: list[PlanCandidate] = []
    for concept in snapshot.concepts:
        prereq_objectives = []
        for source in prereq_by_concept.get(concept.concept_id, []):
            prereq_objectives.extend(item.objective_id for item in objectives_by_concept.get(source, []))
        for objective in concept.objectives:
            state = session.get(LearnerObjectiveState, (goal.user_id, objective.objective_id))
            relevance = 1.0
            if goal.target_depth == "overview" and objective.cognitive_dimension == "application":
                relevance = 0.35
            candidates.append(
                PlanCandidate(
                    objective_id=objective.objective_id,
                    concept_id=concept.concept_id,
                    title=concept.title,
                    prereq_objective_ids=tuple(prereq_objectives),
                    status=state.status if state else "unknown",
                    mastery=state.mastery_estimate if state else 0.0,
                    confidence=state.confidence if state else 0.0,
                    estimated_minutes=12,
                    goal_relevance=relevance,
                    has_due_review=objective.objective_id in due_now,
                    step_type="learn",
                )
            )
    return candidates


def new_private_graph_slug(user: User, topic: str) -> str:
    return f"{str(user.id)[:8]}-{slugify(topic)}"


def graph_for_topic(session: Session, topic: str):
    return find_graph_for_topic(session, topic)


def fresh_goal_id() -> UUID:
    return uuid4()
