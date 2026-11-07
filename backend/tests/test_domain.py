from datetime import datetime, timedelta, timezone
from uuid import uuid4

import pytest

from app.features.goals_trajectories.planner import PlanCandidate, plan_trajectory
from app.features.graph_evolution.policies import (
    EvidenceRef,
    ExplicitMap,
    ObjectiveRef,
    build_directives,
    merge_evidence,
)
from app.features.knowledge_graph.domain import (
    ConceptNode,
    EdgeNode,
    GraphValidationError,
    ObjectiveNode,
    ReleaseSnapshot,
    validate_snapshot,
)
from app.features.learning_sessions.grading import grade_deterministic
from app.features.mastery.project import EvidenceView, project_objective
from app.features.retention.fsrs_adapter import new_card_state, rating_from_score, review_state


def _concept(title: str) -> ConceptNode:
    return ConceptNode(
        concept_id=uuid4(),
        title=title,
        summary=title,
        objectives=[ObjectiveNode(uuid4(), f"do {title}", "understanding")],
    )


def test_prerequisite_cycle_is_rejected():
    a, b = _concept("A"), _concept("B")
    snapshot = ReleaseSnapshot(
        concepts=[a, b],
        edges=[
            EdgeNode(uuid4(), a.concept_id, b.concept_id, "prerequisite", False),
            EdgeNode(uuid4(), b.concept_id, a.concept_id, "prerequisite", False),
        ],
    )
    with pytest.raises(GraphValidationError) as raised:
        validate_snapshot(snapshot, max_nodes=12, max_depth=4, max_fanout=8)
    assert raised.value.reason == "prerequisite_cycle"


def test_related_edges_may_cycle():
    a, b = _concept("A"), _concept("B")
    snapshot = ReleaseSnapshot(
        concepts=[a, b],
        edges=[
            EdgeNode(uuid4(), a.concept_id, b.concept_id, "related", False),
            EdgeNode(uuid4(), b.concept_id, a.concept_id, "related", False),
        ],
    )
    validate_snapshot(snapshot, max_nodes=12, max_depth=4, max_fanout=8)


def test_planner_changes_with_prior_knowledge():
    root = uuid4()
    leaf = uuid4()
    root_obj, leaf_obj = uuid4(), uuid4()
    concept_root, concept_leaf = uuid4(), uuid4()

    def candidates(root_status: str) -> list[PlanCandidate]:
        return [
            PlanCandidate(root_obj, concept_root, "Root", (), root_status, 0.9 if root_status == "demonstrated" else 0, 0.8, 10, 1, False, "learn"),
            PlanCandidate(leaf_obj, concept_leaf, "Leaf", (root_obj,), "unknown", 0, 0, 10, 1, False, "learn"),
        ]

    novice = plan_trajectory(candidates("unknown"))
    ready = plan_trajectory(candidates("demonstrated"))
    assert novice[0].objective_id == root_obj
    assert ready[0].objective_id == leaf_obj
    assert root != leaf


def test_self_report_cannot_look_like_mastery():
    projected = project_objective([EvidenceView(1.0, 1.0, "self_report", "recall")])
    assert projected.status != "demonstrated"
    assert projected.confidence < 0.2


def test_demonstrated_requires_real_evidence():
    rows = [EvidenceView(0.9, 1.0, "keyword", "application") for _ in range(4)]
    projected = project_objective(rows)
    assert projected.status == "demonstrated"


def test_unknown_when_no_evidence():
    assert project_objective([]).status == "unknown"


def test_split_transfers_only_mapped_objective():
    broad, feed, cnn = uuid4(), uuid4(), uuid4()
    concept = uuid4()
    before = [
        ObjectiveRef(broad, concept, "b", "broad"),
        ObjectiveRef(feed, concept, "f", "feedforward"),
    ]
    after = [
        ObjectiveRef(uuid4(), uuid4(), "ff", "feedforward nets"),
        ObjectiveRef(cnn, uuid4(), "cnn", "cnns"),
    ]
    target_feed = after[0].objective_id
    directives = build_directives(
        before,
        after,
        [ExplicitMap(feed, target_feed, "remap", 1)],
        [EvidenceRef(uuid4(), uuid4(), feed, "application", 0.9, 1, "keyword", uuid4(), uuid4())],
        [],
    )
    remap = [item for item in directives if item.policy == "remap"]
    unknown = [item for item in directives if item.target_objective_id == cnn]
    assert len(remap) == 1
    assert remap[0].transfer_evidence_ids
    assert unknown[0].policy == "unknown"
    assert not unknown[0].transfer_evidence_ids


def test_merge_dedupes_same_attempt():
    attempt = uuid4()
    row_a = EvidenceRef(uuid4(), attempt, uuid4(), "recall", 0.8, 1, "keyword", uuid4(), uuid4())
    row_b = EvidenceRef(uuid4(), attempt, uuid4(), "recall", 0.8, 1, "keyword", uuid4(), uuid4())
    other = EvidenceRef(uuid4(), uuid4(), uuid4(), "recall", 0.4, 1, "keyword", uuid4(), uuid4())
    merged = merge_evidence([[row_a], [row_b, other]])
    assert len(merged) == 2


def test_keyword_grader_and_mcq():
    mcq = grade_deterministic(
        "multiple_choice",
        {"answer": {"choice": "A"}, "choices": []},
        {"mode": "exact_choice", "dimension": "recall"},
        {"choice": "A"},
    )
    assert mcq is not None and mcq.score == 1
    keyword = grade_deterministic(
        "retrieval_short_answer",
        {"prompt": "entropy"},
        {"mode": "keyword", "must_include": ["entropy"], "dimension": "recall"},
        {"text": "Entropy measures uncertainty"},
    )
    assert keyword is not None and keyword.score == 1


def test_fsrs_review_moves_due_and_keeps_history_shape():
    now = datetime(2026, 11, 7, tzinfo=timezone.utc)
    state = new_card_state(now)
    after, event = review_state(state, rating_from_score(0.95), now)
    assert after["due"] != state["due"]
    assert event["scheduler_version"] == "fsrs-6.3.2"
    later = now + timedelta(days=3)
    again, second = review_state(after, "again", later)
    assert second["rating_name"] == "again"
    assert again["scheduler_version"] == "fsrs-6.3.2"
