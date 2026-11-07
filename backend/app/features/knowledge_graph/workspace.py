from __future__ import annotations

from uuid import UUID

from sqlmodel import Session, col, select

from app.features.accounts.models import User
from app.features.goals_trajectories.models import LearningGoal, Trajectory, TrajectoryStep
from app.features.graph_evolution.models import GraphChangeProposal
from app.features.knowledge_graph.identity import is_placeholder_title
from app.features.knowledge_graph.models import GraphRelease
from app.features.knowledge_graph.service import load_snapshot, release_diff, shared_graph
from app.features.mastery.service import concept_rollup


def workspace_graph(session: Session, user: User, trajectory_id: UUID | None = None) -> dict:
    """The one shared graph, with this learner's mastery and one trajectory highlighted."""
    graph = shared_graph(session)
    nodes: dict[str, dict] = {}
    edges: dict[str, dict] = {}
    release = session.get(GraphRelease, graph.active_release_id) if graph.active_release_id else None
    if release is not None:
        snapshot = load_snapshot(session, release.id)
        titles = {concept.title for concept in snapshot.concepts}
        for concept in snapshot.concepts:
            if concept.title.lower().endswith(" practice") or is_placeholder_title(concept.title, titles):
                continue
            concept_id = str(concept.concept_id)
            rollup = concept_rollup(
                session,
                user.id,
                concept.concept_id,
                [item.objective_id for item in concept.objectives],
            )
            nodes[concept_id] = {
                "concept_id": concept_id,
                "title": concept.title,
                "summary": concept.summary,
                "mastery_status": rollup["status"],
                "estimate": rollup["estimate"],
                "confidence": rollup["confidence"],
                "status": "published",
                "change": None,
                "graph_id": str(graph.id),
                "goal_id": None,
                "release_id": str(release.id),
                "objectives": [
                    {"id": str(item.objective_id), "statement": item.statement}
                    for item in concept.objectives
                ],
            }
        for edge in snapshot.edges:
            if str(edge.from_concept_id) not in nodes or str(edge.to_concept_id) not in nodes:
                continue
            edge_id = str(edge.edge_id)
            edges[edge_id] = {
                "edge_id": edge_id,
                "from_concept_id": str(edge.from_concept_id),
                "to_concept_id": str(edge.to_concept_id),
                "type": edge.type,
                "status": "published",
            }
        if release.parent_release_id is not None:
            diff = release_diff(session, release.parent_release_id, release.id)
            for item in diff["concepts_added"]:
                node = nodes.get(item["concept_id"])
                if node is not None:
                    node["change"] = "new"
            for item in diff["concepts_revised"]:
                node = nodes.get(item["concept_id"])
                if node is not None and node["change"] is None:
                    node["change"] = "changed"
        _proposed(session, user, graph.id, nodes, edges)

    trajectory = _trajectory(session, user, trajectory_id)
    concept_ids: list[str] = []
    goal_payload = None
    if trajectory is not None:
        steps = session.exec(select(TrajectoryStep).where(TrajectoryStep.trajectory_id == trajectory.id)).all()
        concept_ids = [str(step.concept_id) for step in sorted(steps, key=lambda item: item.rank)]
        goal = session.get(LearningGoal, trajectory.goal_id)
        if goal is not None:
            goal_payload = {
                "id": str(goal.id),
                "title": goal.title,
                "graph_id": str(graph.id),
                "release_id": str(release.id) if release is not None else None,
                "trajectory_id": str(trajectory.id),
            }
            for node in nodes.values():
                node["goal_id"] = str(goal.id)
    return {
        "nodes": list(nodes.values()),
        "edges": list(edges.values()),
        "trajectory_concept_ids": [item for item in concept_ids if item in nodes],
        "goal": goal_payload,
    }


def _trajectory(session: Session, user: User, trajectory_id: UUID | None) -> Trajectory | None:
    if trajectory_id is not None:
        trajectory = session.get(Trajectory, trajectory_id)
        if trajectory is None:
            return None
        goal = session.get(LearningGoal, trajectory.goal_id)
        if goal is None or goal.user_id != user.id or goal.status == "deleted":
            return None
        return trajectory
    goal = session.exec(
        select(LearningGoal)
        .where(LearningGoal.user_id == user.id, LearningGoal.status != "deleted")
        .order_by(LearningGoal.created_at.desc())
    ).first()
    if goal is None:
        return None
    return session.exec(select(Trajectory).where(Trajectory.goal_id == goal.id).order_by(Trajectory.version.desc())).first()


def _proposed(session: Session, user: User, graph_id: UUID, nodes: dict[str, dict], edges: dict[str, dict]) -> None:
    proposals = session.exec(
        select(GraphChangeProposal).where(
            GraphChangeProposal.graph_id == graph_id,
            col(GraphChangeProposal.status).in_(["proposed", "validated"]),
        )
    ).all()
    for proposal in proposals:
        if proposal.actor_user_id not in {None, user.id}:
            continue
        diff = proposal.diff or {}
        for concept in diff.get("concepts_added") or []:
            title = str(concept.get("title") or "Proposed")
            known = {str(node.get("title") or "") for node in nodes.values()} | {title}
            if title.lower().endswith(" practice") or is_placeholder_title(title, known):
                continue
            concept_id = str(concept["concept_id"])
            if concept_id in nodes:
                continue
            nodes[concept_id] = {
                "concept_id": concept_id,
                "title": title,
                "summary": "",
                "mastery_status": "unknown",
                "estimate": 0.0,
                "confidence": 0.0,
                "status": "proposed",
                "change": "new",
                "proposal_id": str(proposal.id),
                "graph_id": str(graph_id),
                "goal_id": None,
                "release_id": None,
                "objectives": [],
            }
        for edge in diff.get("edges_added") or []:
            edge_id = str(edge.get("edge_id") or f"{edge.get('from_concept_id')}:{edge.get('to_concept_id')}:{edge.get('type')}")
            if edge_id in edges:
                continue
            edges[edge_id] = {
                "edge_id": edge_id,
                "from_concept_id": str(edge.get("from_concept_id")),
                "to_concept_id": str(edge.get("to_concept_id")),
                "type": edge.get("type") or "related",
                "status": "proposed",
                "proposal_id": str(proposal.id),
            }
