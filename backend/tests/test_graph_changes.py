from uuid import uuid4

import pytest
from sqlmodel import select

from app.core.errors import AppError
from app.features.accounts.models import User
from app.features.goals_trajectories.service import attach_graph, create_goal
from app.features.graph_evolution.models import MigrationItem, MigrationRun
from app.features.graph_evolution.service import (
    accept_private,
    run_learner_migration,
    store_proposal,
)
from app.features.knowledge_graph.domain import (
    ConceptNode,
    EdgeNode,
    ObjectiveNode,
    ReleaseSnapshot,
)
from app.features.knowledge_graph.models import Graph
from app.features.knowledge_graph.service import load_snapshot, publish_snapshot
from app.features.learning_sessions.models import AssessmentAttempt
from app.features.mastery.models import LearnerObjectiveState, MasteryEvidence
from app.features.mastery.service import add_evidence
from app.features.retention.models import ReviewItem
from app.features.retention.service import schedule_review
from app.workers.runner import process_until_idle


def _graph(session, user: User, title: str, concepts: list[ConceptNode], edges: list[EdgeNode]) -> tuple[Graph, object]:
    graph = Graph(slug=f"{user.id}-{title}", title=title, owner_user_id=user.id, visibility="private")
    session.add(graph)
    session.flush()
    release = publish_snapshot(
        session,
        graph_id=graph.id,
        base_release_id=None,
        snapshot=ReleaseSnapshot(concepts=concepts, edges=edges),
        actor_user_id=user.id,
    )
    session.commit()
    return graph, release


def _concept(title: str, statement: str) -> tuple[ConceptNode, ObjectiveNode]:
    objective = ObjectiveNode(uuid4(), statement, "application")
    concept = ConceptNode(concept_id=uuid4(), title=title, summary=title, objectives=[objective])
    return concept, objective


def test_publish_rejects_prerequisite_cycle(session, user):
    a, ao = _concept("A", "explain a")
    b, bo = _concept("B", "explain b")
    graph = Graph(slug=f"cycle-{user.id}", title="Cycle", owner_user_id=user.id, visibility="private")
    session.add(graph)
    session.flush()
    with pytest.raises(AppError) as raised:
        publish_snapshot(
            session,
            graph_id=graph.id,
            base_release_id=None,
            snapshot=ReleaseSnapshot(
                concepts=[a, b],
                edges=[
                    EdgeNode(uuid4(), a.concept_id, b.concept_id, "prerequisite", False),
                    EdgeNode(uuid4(), b.concept_id, a.concept_id, "prerequisite", False),
                ],
            ),
            actor_user_id=user.id,
        )
    assert raised.value.code == "INVALID_GRAPH"


def test_branch_expansion_keeps_old_mastery_and_unknown_children(session, user):
    parent, parent_obj = _concept("Decision Trees", "explain a decision tree as a recursive partition")
    graph, release = _graph(session, user, "trees", [parent], [])
    goal = create_goal(session, user, topic="Decision Trees", purpose="x", target_depth="professional", minutes_per_week=60, language="en")
    attach_graph(session, goal, graph.id, release.id)
    goal.status = "active"
    add_evidence(
        session,
        user_id=user.id,
        objective_id=parent_obj.objective_id,
        objective_revision_id=parent_obj.revision_id,
        concept_id=parent.concept_id,
        concept_revision_id=parent.revision_id,
        dimension="understanding",
        score=0.95,
        weight=1,
        method="keyword",
        attempt_id=None,
    )
    schedule_review(
        session,
        user_id=user.id,
        concept_id=parent.concept_id,
        objective_id=parent_obj.objective_id,
        objective_revision_id=parent_obj.revision_id,
        activity_id=None,
        score=0.95,
        rating_override="good",
        attempt_id=None,
    )
    before_state = session.get(LearnerObjectiveState, (user.id, parent_obj.objective_id))
    before_estimate = before_state.mastery_estimate
    before_reviews = len(session.exec(select(ReviewItem).where(ReviewItem.user_id == user.id)).all())
    proposal = store_proposal(
        session,
        graph_id=graph.id,
        base_release_id=release.id,
        actor=user,
        actor_type="user",
        trigger_type="user_expansion",
        operations=[
            {
                "op": "add_concept",
                "temp_id": "entropy",
                "title": "Entropy",
                "summary": "Uncertainty.",
                "parent": str(parent.concept_id),
                "objectives": [{"temp_id": "eo", "statement": "calculate entropy from class frequencies", "cognitive_dimension": "application"}],
            },
            {
                "op": "add_concept",
                "temp_id": "gain",
                "title": "Information Gain",
                "summary": "Impurity reduction.",
                "parent": str(parent.concept_id),
                "objectives": [{"temp_id": "go", "statement": "compute information gain of a candidate split", "cognitive_dimension": "application"}],
            },
        ],
    )
    session.commit()
    result = accept_private(session, user, graph.id, proposal.id, goal.id)
    new_release = load_snapshot(session, result["release_id"])
    titles = {concept.title for concept in new_release.concepts}
    assert {"Entropy", "Information Gain", "Decision Trees"} <= titles
    after_state = session.get(LearnerObjectiveState, (user.id, parent_obj.objective_id))
    assert after_state.mastery_estimate == before_estimate
    new_objectives = [objective for concept in new_release.concepts if concept.title in {"Entropy", "Information Gain"} for objective in concept.objectives]
    for objective in new_objectives:
        state = session.get(LearnerObjectiveState, (user.id, objective.objective_id))
        assert state is None or state.status == "unknown"
    assert len(session.exec(select(ReviewItem).where(ReviewItem.user_id == user.id)).all()) == before_reviews


def test_reparent_preserves_evidence_and_schedule(session, user):
    parent, _parent_obj = _concept("Information Theory", "explain information")
    entropy, entropy_obj = _concept("Entropy", "calculate entropy from class frequencies")
    graph, release = _graph(
        session,
        user,
        "info",
        [parent, entropy],
        [EdgeNode(uuid4(), parent.concept_id, entropy.concept_id, "contains", True)],
    )
    add_evidence(
        session,
        user_id=user.id,
        objective_id=entropy_obj.objective_id,
        objective_revision_id=entropy_obj.revision_id,
        concept_id=entropy.concept_id,
        concept_revision_id=entropy.revision_id,
        dimension="application",
        score=0.9,
        weight=1,
        method="keyword",
        attempt_id=None,
    )
    item = schedule_review(
        session,
        user_id=user.id,
        concept_id=entropy.concept_id,
        objective_id=entropy_obj.objective_id,
        objective_revision_id=entropy_obj.revision_id,
        activity_id=None,
        score=0.9,
        rating_override="good",
        attempt_id=None,
    )
    due = item.due_at
    evidence_ids = [row.id for row in session.exec(select(MasteryEvidence)).all()]
    other, _other_obj = _concept("Probability", "explain probability")
    # Probability is new, so add it in the same proposal as the reparent.
    proposal = store_proposal(
        session,
        graph_id=graph.id,
        base_release_id=release.id,
        actor=user,
        actor_type="user",
        trigger_type="user_reparent",
        operations=[
            {
                "op": "add_concept",
                "temp_id": "prob",
                "title": "Probability",
                "summary": "Probability.",
                "objectives": [{"temp_id": "po", "statement": "explain probability", "cognitive_dimension": "understanding"}],
            },
            {"op": "reparent", "concept_id": str(entropy.concept_id), "parent_concept_id": "prob"},
        ],
    )
    session.commit()
    result = accept_private(session, user, graph.id, proposal.id, None)
    after = load_snapshot(session, result["release_id"])
    moved = after.concept(entropy.concept_id)
    assert moved is not None and moved.revision_id == entropy.revision_id
    session.refresh(item)
    assert item.due_at == due
    assert [row.id for row in session.exec(select(MasteryEvidence).where(MasteryEvidence.migration_origin_id.is_(None))).all()] == evidence_ids


def test_split_does_not_copy_parent_mastery_to_every_child(session, user):
    broad = ObjectiveNode(uuid4(), "survey neural networks", "understanding")
    feed = ObjectiveNode(uuid4(), "explain a feedforward layer", "understanding")
    concept = ConceptNode(concept_id=uuid4(), title="Neural Networks", summary="Broad", objectives=[broad, feed])
    graph, release = _graph(session, user, "nn", [concept], [])
    from app.features.learning_content.models import LearningActivity
    activity = LearningActivity(
        concept_revision_id=concept.revision_id,
        kind="teach_back",
        body={"prompt": "survey"},
        rubric={"mode": "keyword"},
        content_hash=str(uuid4()),
        prompt_version="t",
        model="fake",
    )
    session.add(activity)
    session.flush()
    broad_attempt = AssessmentAttempt(
        user_id=user.id,
        activity_id=activity.id,
        concept_revision_id=concept.revision_id,
        response={"text": "survey"},
        score=0.2,
        grading_method="keyword",
    )
    feed_attempt = AssessmentAttempt(
        user_id=user.id,
        activity_id=activity.id,
        concept_revision_id=concept.revision_id,
        response={"text": "feedforward"},
        score=0.9,
        grading_method="keyword",
    )
    session.add(broad_attempt)
    session.add(feed_attempt)
    session.flush()
    add_evidence(session, user_id=user.id, objective_id=broad.objective_id, objective_revision_id=broad.revision_id, concept_id=concept.concept_id, concept_revision_id=concept.revision_id, dimension="understanding", score=0.2, weight=1, method="keyword", attempt_id=broad_attempt.id)
    add_evidence(session, user_id=user.id, objective_id=feed.objective_id, objective_revision_id=feed.revision_id, concept_id=concept.concept_id, concept_revision_id=concept.revision_id, dimension="understanding", score=0.95, weight=1, method="keyword", attempt_id=feed_attempt.id)
    feed_target = uuid4()
    cnn_target = uuid4()
    proposal = store_proposal(
        session,
        graph_id=graph.id,
        base_release_id=release.id,
        actor=user,
        actor_type="user",
        trigger_type="split",
        operations=[
            {"op": "remove_concept", "concept_id": str(concept.concept_id)},
            {"op": "add_concept", "temp_id": "ff", "title": "Feedforward Networks", "summary": "Layers", "objectives": [{"temp_id": "ffo", "objective_id": str(feed_target), "statement": "explain a feedforward layer", "cognitive_dimension": "understanding"}]},
            {"op": "add_concept", "temp_id": "cnn", "title": "CNNs", "summary": "Convolutions", "objectives": [{"temp_id": "co", "objective_id": str(cnn_target), "statement": "explain a convolution", "cognitive_dimension": "understanding"}]},
        ],
        objective_maps=[{"source_objective_id": str(feed.objective_id), "target_objective_id": str(feed_target), "policy": "remap"}],
    )
    session.commit()
    before_attempt = (broad_attempt.response, broad_attempt.score)
    result = accept_private(session, user, graph.id, proposal.id, None)
    session.refresh(broad_attempt)
    assert (broad_attempt.response, broad_attempt.score) == before_attempt
    copied = session.exec(select(MasteryEvidence).where(MasteryEvidence.objective_id == feed_target)).all()
    cnn_rows = session.exec(select(MasteryEvidence).where(MasteryEvidence.objective_id == cnn_target)).all()
    assert len(copied) == 1
    assert copied[0].migration_origin_id is not None
    assert cnn_rows == []
    assert result["status"] == "succeeded"


def test_merge_dedupes_attempt(session, user):
    left, left_obj = _concept("Gradient Descent Basics", "follow the gradient")
    right, right_obj = _concept("Optimization with Gradient Descent", "follow the gradient")
    graph, release = _graph(session, user, "gd", [left, right], [])
    from app.features.learning_content.models import LearningActivity

    activity = LearningActivity(concept_revision_id=left.revision_id, kind="retrieval_short_answer", body={"prompt": "grad"}, rubric={"mode": "keyword"}, content_hash=str(uuid4()), prompt_version="t", model="fake")
    session.add(activity)
    session.flush()
    attempt = AssessmentAttempt(user_id=user.id, activity_id=activity.id, concept_revision_id=left.revision_id, response={"text": "gradient"}, score=0.8, grading_method="keyword")
    session.add(attempt)
    session.flush()
    add_evidence(session, user_id=user.id, objective_id=left_obj.objective_id, objective_revision_id=left_obj.revision_id, concept_id=left.concept_id, concept_revision_id=left.revision_id, dimension="recall", score=0.8, weight=1, method="keyword", attempt_id=attempt.id)
    add_evidence(session, user_id=user.id, objective_id=right_obj.objective_id, objective_revision_id=right_obj.revision_id, concept_id=right.concept_id, concept_revision_id=right.revision_id, dimension="recall", score=0.8, weight=1, method="keyword", attempt_id=attempt.id)
    target = uuid4()
    proposal = store_proposal(
        session,
        graph_id=graph.id,
        base_release_id=release.id,
        actor=user,
        actor_type="user",
        trigger_type="merge",
        operations=[
            {"op": "remove_concept", "concept_id": str(left.concept_id)},
            {"op": "remove_concept", "concept_id": str(right.concept_id)},
            {"op": "add_concept", "temp_id": "merged", "title": "Gradient Descent", "summary": "Merged", "objectives": [{"temp_id": "mo", "objective_id": str(target), "statement": "follow the gradient", "cognitive_dimension": "application"}]},
        ],
        objective_maps=[
            {"source_objective_id": str(left_obj.objective_id), "target_objective_id": str(target), "policy": "remap"},
            {"source_objective_id": str(right_obj.objective_id), "target_objective_id": str(target), "policy": "remap"},
        ],
    )
    session.commit()
    accept_private(session, user, graph.id, proposal.id, None)
    copied = session.exec(select(MasteryEvidence).where(MasteryEvidence.objective_id == target)).all()
    assert len(copied) == 1


def test_revised_fact_needs_reassessment_and_keeps_attempt(session, user):
    concept, objective = _concept("Activation", "sigmoid is the only activation")
    graph, release = _graph(session, user, "act", [concept], [])
    from app.features.learning_content.models import LearningActivity

    activity = LearningActivity(concept_revision_id=concept.revision_id, kind="retrieval_short_answer", body={"prompt": "sigmoid"}, rubric={"mode": "keyword"}, content_hash=str(uuid4()), prompt_version="t", model="fake")
    session.add(activity)
    session.flush()
    attempt = AssessmentAttempt(user_id=user.id, activity_id=activity.id, concept_revision_id=concept.revision_id, response={"text": "sigmoid"}, score=1, grading_method="keyword")
    session.add(attempt)
    session.flush()
    snapshot = (dict(attempt.response), attempt.score, attempt.concept_revision_id)
    add_evidence(session, user_id=user.id, objective_id=objective.objective_id, objective_revision_id=objective.revision_id, concept_id=concept.concept_id, concept_revision_id=concept.revision_id, dimension="recall", score=1, weight=1, method="keyword", attempt_id=attempt.id)
    proposal = store_proposal(
        session,
        graph_id=graph.id,
        base_release_id=release.id,
        actor=user,
        actor_type="maintainer",
        trigger_type="correction",
        risk_class="high",
        sources=[{"url": "https://example.com/activations", "trust_tier": "verified"}],
        operations=[{"op": "revise_concept", "concept_id": str(concept.concept_id), "summary": "Many activations exist.", "objectives": [{"objective_id": str(objective.objective_id), "statement": "name two modern activation functions"}]}],
    )
    session.commit()
    accept_private(session, user, graph.id, proposal.id, None)
    session.refresh(attempt)
    assert (dict(attempt.response), attempt.score, attempt.concept_revision_id) == snapshot
    state = session.get(LearnerObjectiveState, (user.id, objective.objective_id))
    assert state.status == "needs_reassessment"


def test_migration_retry_does_not_duplicate(session, user):
    concept, objective = _concept("Entropy", "calculate entropy from class frequencies")
    other, other_obj = _concept("Gain", "compute information gain")
    graph, release = _graph(session, user, "retry", [concept], [])
    add_evidence(session, user_id=user.id, objective_id=objective.objective_id, objective_revision_id=objective.revision_id, concept_id=concept.concept_id, concept_revision_id=concept.revision_id, dimension="application", score=0.9, weight=1, method="keyword", attempt_id=None)
    proposal = store_proposal(
        session,
        graph_id=graph.id,
        base_release_id=release.id,
        actor=user,
        actor_type="user",
        trigger_type="split",
        operations=[
            {"op": "remove_concept", "concept_id": str(concept.concept_id)},
            {"op": "add_concept", "temp_id": "n", "title": "Entropy detail", "summary": "d", "objectives": [{"temp_id": "o", "objective_id": str(other_obj.objective_id), "statement": "calculate entropy from class frequencies", "cognitive_dimension": "application"}]},
        ],
        objective_maps=[{"source_objective_id": str(objective.objective_id), "target_objective_id": str(other_obj.objective_id), "policy": "remap"}],
    )
    session.commit()
    first = accept_private(session, user, graph.id, proposal.id, None)
    count = len(session.exec(select(MasteryEvidence).where(MasteryEvidence.objective_id == other_obj.objective_id)).all())
    run = session.get(MigrationRun, first["migration_id"])
    run.status = "running"
    for item in session.exec(select(MigrationItem).where(MigrationItem.migration_run_id == run.id)).all():
        if item.policy == "remap":
            item.result = None
            session.add(item)
    session.add(run)
    session.commit()
    second = run_learner_migration(session, user_id=user.id, from_release_id=release.id, to_release_id=run.to_release_id, proposal_id=proposal.id, goal_id=None)
    assert second.id == run.id
    assert second.status == "succeeded"
    assert len(session.exec(select(MasteryEvidence).where(MasteryEvidence.objective_id == other_obj.objective_id)).all()) == count
    _ = other


def test_concurrent_publish_one_stale(session, user):
    concept, _objective = _concept("Root", "explain root")
    graph, release = _graph(session, user, "race", [concept], [])
    from threading import Thread

    from sqlmodel import Session as DBSession

    from app.core.db import engine

    results = []

    def attempt(title: str):
        extra, _obj = _concept(title, f"explain {title}")
        with DBSession(engine, expire_on_commit=False) as db:
            try:
                loaded = __import__("app.features.knowledge_graph.service", fromlist=["load_snapshot"]).load_snapshot(db, release.id)
                loaded.concepts.append(extra)
                publish_snapshot(db, graph_id=graph.id, base_release_id=release.id, snapshot=loaded, actor_user_id=user.id)
                db.commit()
                results.append("ok")
            except AppError as exc:
                db.rollback()
                results.append(exc.code)

    threads = [Thread(target=attempt, args=(f"Child {index}",)) for index in range(2)]
    for thread in threads:
        thread.start()
    for thread in threads:
        thread.join()
    assert sorted(results) == ["GRAPH_STALE", "ok"]


def test_job_claim_skip_locked(session, user):
    from sqlmodel import Session as DBSession

    from app.core.db import engine
    from app.features.platform.jobs import claim_next, enqueue

    enqueue(session, job_type="noop", user_id=user.id, payload={"n": 1})
    enqueue(session, job_type="noop", user_id=user.id, payload={"n": 2})
    session.commit()
    with DBSession(engine, expire_on_commit=False) as first, DBSession(engine, expire_on_commit=False) as second:
        claimed_a = claim_next(first)
        claimed_b = claim_next(second)
        assert claimed_a is not None and claimed_b is not None
        assert claimed_a[0].id != claimed_b[0].id


def test_openapi_contains_contract_paths(client):
    paths = client.get("/openapi.json").json()["paths"]
    expected = [
        "/api/v1/goals",
        "/api/v1/graphs/{graph_id}/expansions",
        "/api/v1/graphs/{graph_id}/migration-preview",
        "/api/v1/learning-sessions/{session_id}/attempts",
        "/api/v1/reviews/due",
        "/api/v1/mastery/overview",
        "/api/v1/me",
    ]
    for path in expected:
        assert path in paths


def test_freshness_job_is_off_by_default(client, auth, session, user):
    from app.features.platform.jobs import enqueue

    user.is_admin = True
    session.add(user)
    session.commit()
    concept, _objective = _concept("API", "call an endpoint")
    concept.knowledge_type = "software_versioned"
    graph, _release = _graph(session, user, "api", [concept], [])
    job = enqueue(session, job_type="freshness_check", user_id=user.id, payload={"graph_id": str(graph.id)})
    session.commit()
    process_until_idle()
    body = client.get(f"/api/v1/jobs/{job.id}", headers=auth).json()
    assert body["state"] == "succeeded"
    assert body["result"]["skipped"] is True


def test_sentry_stays_off_without_dsn():
    from app.core.logging import setup_sentry

    assert setup_sentry("") is False


def test_expired_lease_is_reclaimed_and_backoff_hides_the_retry(session, user):
    from datetime import timedelta

    from app.core.time import utcnow
    from app.features.platform.jobs import claim_next, enqueue, retry_later

    job = enqueue(session, job_type="noop", user_id=user.id, payload={})
    session.commit()
    claimed, token = claim_next(session)
    claimed.lease_until = utcnow() - timedelta(seconds=1)
    session.add(claimed)
    session.commit()
    again, token_2 = claim_next(session)
    assert again.id == job.id
    assert token_2 != token
    retry_later(session, again.id, token_2, "TRANSIENT", "later")
    assert claim_next(session) is None


def test_cached_activity_survives_a_down_provider(session, user, monkeypatch):
    from app.features.knowledge_graph.service import load_snapshot, seed_decision_trees
    from app.features.learning_content.service import generate_activity

    graph = seed_decision_trees(session)
    session.commit()
    concept = load_snapshot(session, graph.active_release_id).concepts[0]
    calls = {"n": 0}

    class Down:
        name = "down"

        def generate_activity(self, payload):
            calls["n"] += 1
            if calls["n"] > 1:
                raise RuntimeError("provider down")
            return (
                {"content": {"prompt": payload["statement"]}, "rubric": {"mode": "keyword", "must_include": ["partition"]}, "prompt_version": "activity_v1"},
                {"model": "fake", "input_tokens": 1, "output_tokens": 1, "cost_usd": 0},
            )

    monkeypatch.setattr("app.features.learning_content.service.get_provider", lambda: Down())
    objective = concept.objectives[0]
    kwargs = {
        "user_id": user.id,
        "job_id": None,
        "concept_revision_id": concept.revision_id,
        "concept_title": concept.title,
        "objectives": [{"id": str(objective.objective_id), "revision_id": str(objective.revision_id), "statement": objective.statement}],
        "kind": "explain",
    }
    first = generate_activity(session, **kwargs)
    session.commit()
    second = generate_activity(session, **kwargs)
    assert second.id == first.id
    assert calls["n"] == 1
