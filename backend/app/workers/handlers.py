from __future__ import annotations

from uuid import UUID

from sqlmodel import Session

from app.core.config import get_settings
from app.core.db import engine
from app.core.errors import AppError
from app.core.time import utcnow
from app.features.accounts.models import User
from app.features.goals_trajectories.models import LearningGoal
from app.features.goals_trajectories.service import attach_graph, replan
from app.features.graph_evolution.apply import apply_operations
from app.features.graph_evolution.service import store_proposal
from app.features.knowledge_graph.domain import (
    ConceptNode,
    EdgeNode,
    ObjectiveNode,
    ReleaseSnapshot,
)
from app.features.knowledge_graph.service import load_snapshot, publish_snapshot
from app.features.learning_content.service import generate_activity
from app.features.platform.jobs import finish
from app.features.platform.llm import assert_user_quota, get_provider, record_usage
from app.features.platform.models import GenerationJob, WorkerHeartbeat


def handle(job_id: UUID, token: UUID) -> None:
    with Session(engine, expire_on_commit=False) as session:
        job = session.get(GenerationJob, job_id)
        if job is None:
            return
        dispatch = {
            "noop": _noop,
            "prepare_goal": _prepare_goal,
            "generate_activity": _generate_activity,
            "expand_graph": _expand_graph,
            "freshness_check": _freshness,
        }
        fn = dispatch.get(job.type)
        if fn is None:
            raise AppError("NOT_FOUND", f"Unknown job type {job.type}", 404)
        result = fn(session, job)
        finish(session, job_id, token, result)


def _noop(session: Session, job: GenerationJob) -> dict:
    beat = session.get(WorkerHeartbeat, "worker")
    if beat is None:
        session.add(WorkerHeartbeat(id="worker", beat_at=utcnow()))
    else:
        beat.beat_at = utcnow()
        session.add(beat)
    session.commit()
    return {"ok": True, "payload": job.payload}


def _prepare_goal(session: Session, job: GenerationJob) -> dict:
    goal = session.get(LearningGoal, UUID(job.payload["goal_id"]))
    if goal is None:
        raise AppError("NOT_FOUND", "Goal missing", 404)
    user = session.get(User, goal.user_id)
    if user is None:
        raise AppError("NOT_FOUND", "User missing", 404)
    from sqlalchemy.orm.attributes import flag_modified

    from app.features.goals_trajectories.service import focus_concepts
    from app.features.knowledge_graph.identity import neighborhood, same_topic
    from app.features.knowledge_graph.service import shared_graph

    graph = shared_graph(session)
    existing = load_snapshot(session, graph.active_release_id) if graph.active_release_id else ReleaseSnapshot()
    titles = {concept.title for concept in existing.concepts}
    matched = next(
        (concept for concept in existing.concepts if same_topic(concept.canonical_key or concept.title, goal.topic)),
        None,
    )
    release_id = graph.active_release_id
    snapshot = existing
    if matched is None or not _has_real_children(existing, matched.concept_id, titles):
        assert_user_quota(session, user.id)
        provider = get_provider()
        proposal, usage = provider.propose_graph_branch(
            {
                "topic": goal.topic,
                "purpose": goal.purpose,
                "depth": goal.target_depth,
                "language": goal.language,
                "existing": neighborhood(session),
            }
        )
        record_usage(session, user_id=user.id, job_id=job.id, task="propose_graph_branch", provider=provider.name, usage=usage)
        branch = _snapshot_from_branch(proposal)
        snapshot = ReleaseSnapshot(
            concepts=[*existing.concepts, *branch.concepts],
            edges=[*existing.edges, *branch.edges],
        )
        release = publish_snapshot(
            session,
            graph_id=graph.id,
            base_release_id=graph.active_release_id,
            snapshot=snapshot,
            actor_user_id=user.id,
        )
        release_id = release.id
    if release_id is None:
        raise AppError("INVALID_GRAPH", "Shared graph has no release", 422)
    attach_graph(session, goal, graph.id, release_id, None)
    outcomes = dict(goal.target_outcomes or {})
    outcomes["focus_concept_ids"] = [str(concept.concept_id) for concept in focus_concepts(snapshot, goal.topic)]
    goal.target_outcomes = outcomes
    flag_modified(goal, "target_outcomes")
    goal.status = "active"
    session.add(goal)
    session.flush()
    replan(session, goal, "goal_ready")
    session.commit()
    return {"goal_id": str(goal.id), "graph_id": str(graph.id), "graph_release_id": str(release_id)}


def _has_real_children(snapshot: ReleaseSnapshot, concept_id: UUID, titles: set[str]) -> bool:
    from app.features.knowledge_graph.identity import is_placeholder_title

    child_ids = [edge.to_concept_id for edge in snapshot.edges if edge.type == "contains" and edge.from_concept_id == concept_id]
    for child_id in child_ids:
        child = snapshot.concept(child_id)
        if child is None:
            continue
        if child.title.lower().endswith(" practice") or is_placeholder_title(child.title, titles):
            continue
        return True
    return False


def _generate_activity(session: Session, job: GenerationJob) -> dict:
    payload = job.payload
    if job.user_id:
        assert_user_quota(session, job.user_id)
    activity = generate_activity(
        session,
        user_id=job.user_id,
        job_id=job.id,
        concept_revision_id=UUID(payload["concept_revision_id"]),
        concept_title=payload.get("concept_title") or "",
        objectives=payload["objectives"],
        kind=payload["kind"],
        language=payload.get("language") or "en",
        difficulty=int(payload.get("difficulty") or 1),
        source_hash=payload.get("source_hash") or "none",
        band=payload.get("band") or "new",
    )
    session.commit()
    return {"activity_id": str(activity.id), "content_hash": activity.content_hash}


def _expand_graph(session: Session, job: GenerationJob) -> dict:
    payload = job.payload
    user = session.get(User, job.user_id) if job.user_id else None
    if user is None:
        raise AppError("NOT_FOUND", "User missing", 404)
    assert_user_quota(session, user.id)
    base = load_snapshot(session, UUID(payload["base_release_id"]))
    parent = base.concept(UUID(payload["parent_concept_id"]))
    if parent is None:
        raise AppError("INVALID_GRAPH", "Parent concept is not in the base release", 422)
    provider = get_provider()
    from app.features.knowledge_graph.identity import neighborhood

    branch, usage = provider.propose_graph_branch(
        {
            "topic": parent.title,
            "instruction": payload.get("instruction"),
            "parent_concept_id": str(parent.concept_id),
            "max_new_concepts": payload.get("max_new_concepts"),
            "existing": neighborhood(session),
        }
    )
    record_usage(session, user_id=user.id, job_id=job.id, task="propose_graph_branch", provider=provider.name, usage=usage)
    operations = _branch_operations(branch, str(parent.concept_id))
    proposal = store_proposal(
        session,
        graph_id=UUID(payload["graph_id"]),
        base_release_id=UUID(payload["base_release_id"]),
        actor=user,
        actor_type="user",
        trigger_type="user_expansion",
        operations=operations,
        risk_class="medium",
        sources=branch.get("sources") or [],
        idempotency_key=job.idempotency_key,
    )
    session.commit()
    return {"proposal_id": str(proposal.id), "status": proposal.status}


def _freshness(session: Session, job: GenerationJob) -> dict:
    if not get_settings().graph_freshness_check_enabled:
        session.commit()
        return {"skipped": True, "reason": "GRAPH_FRESHNESS_CHECK_ENABLED is false"}
    graph_id = UUID(job.payload["graph_id"])
    from app.features.knowledge_graph.models import Graph as GraphModel

    graph = session.get(GraphModel, graph_id)
    if graph is None or graph.active_release_id is None:
        return {"skipped": True, "reason": "no_release"}
    snapshot = load_snapshot(session, graph.active_release_id)
    candidates = [
        {"concept_id": str(concept.concept_id), "title": concept.title, "knowledge_type": concept.knowledge_type}
        for concept in snapshot.concepts
        if concept.knowledge_type in {"software_versioned", "time_sensitive", "evolving_research"}
    ]
    session.commit()
    return {"candidates": candidates, "checked": len(snapshot.concepts)}


def _snapshot_from_branch(payload: dict) -> ReleaseSnapshot:
    temp: dict[str, UUID] = {}
    concepts: list[ConceptNode] = []
    for node in payload.get("nodes") or []:
        concept_id = UUID(node["concept_id"]) if node.get("concept_id") else __import__("uuid").uuid4()
        temp[node.get("temp_id") or str(concept_id)] = concept_id
        objectives = []
        for item in node.get("objectives") or []:
            objective_id = UUID(item["objective_id"]) if item.get("objective_id") else __import__("uuid").uuid4()
            temp[item.get("temp_id") or str(objective_id)] = objective_id
            objectives.append(
                ObjectiveNode(
                    objective_id=objective_id,
                    statement=item["statement"],
                    cognitive_dimension=item.get("cognitive_dimension") or "understanding",
                )
            )
        from app.features.knowledge_graph.identity import canonical_key_for

        concepts.append(
            ConceptNode(
                concept_id=concept_id,
                title=node["title"],
                summary=node.get("summary") or "",
                knowledge_type=node.get("knowledge_type") or "timeless_foundation",
                change_kind="initial",
                source_status="source_pending",
                objectives=objectives,
                canonical_key=node.get("canonical_key") or canonical_key_for(node["title"]),
            )
        )
    edges = []
    for edge in payload.get("edges") or []:
        edges.append(
            EdgeNode(
                edge_id=__import__("uuid").uuid4(),
                from_concept_id=temp[edge["from"]],
                to_concept_id=temp[edge["to"]],
                type=edge["type"],
                is_primary_parent=bool(edge.get("is_primary_parent")),
            )
        )
    return ReleaseSnapshot(concepts=concepts, edges=edges)


def _branch_operations(payload: dict, parent_concept_id: str) -> list[dict]:
    operations = []
    nodes = payload.get("nodes") or []
    for index, node in enumerate(nodes):
        parent = node.get("parent") or (parent_concept_id if index == 0 else nodes[0].get("temp_id"))
        operations.append(
            {
                "op": "add_concept",
                "temp_id": node.get("temp_id") or f"n{index}",
                "title": node["title"],
                "summary": node.get("summary") or "",
                "knowledge_type": node.get("knowledge_type") or "timeless_foundation",
                "source_status": "source_pending",
                "canonical_key": node.get("canonical_key"),
                "parent": parent,
                "objectives": [
                    {
                        "temp_id": item.get("temp_id") or f"o{index}-{offset}",
                        "statement": item["statement"],
                        "cognitive_dimension": item.get("cognitive_dimension") or "understanding",
                    }
                    for offset, item in enumerate(node.get("objectives") or [])
                ],
            }
        )
    for edge in payload.get("edges") or []:
        if edge.get("type") == "contains":
            continue
        operations.append(
            {
                "op": "add_edge",
                "from": edge["from"],
                "to": edge["to"],
                "type": edge["type"],
                "is_primary_parent": bool(edge.get("is_primary_parent")),
            }
        )
    _ = apply_operations
    return operations
