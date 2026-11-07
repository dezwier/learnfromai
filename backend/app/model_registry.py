"""Import every table model so SQLModel.metadata is complete."""

from app.features.accounts.models import User
from app.features.goals_trajectories.models import (
    GoalGraph,
    LearningGoal,
    Trajectory,
    TrajectoryRelease,
    TrajectoryStep,
)
from app.features.graph_evolution.models import (
    ConceptMapping,
    GraphChangeProposal,
    MigrationItem,
    MigrationRun,
    ObjectiveMapping,
)
from app.features.knowledge_graph.models import (
    Concept,
    ConceptRevision,
    Edge,
    EdgeRevision,
    Graph,
    GraphOverlay,
    GraphRelease,
    LearningObjective,
    ObjectiveRevision,
    ReleaseConcept,
    ReleaseEdge,
    SourceClaim,
    SourceDocument,
)
from app.features.learning_content.models import ActivityObjective, LearningActivity
from app.features.learning_sessions.models import AssessmentAttempt, LearningSession
from app.features.mastery.models import LearnerObjectiveState, MasteryEvidence
from app.features.platform.models import AuditEvent, GenerationJob, LlmUsage, WorkerHeartbeat
from app.features.retention.models import ReviewEvent, ReviewItem


def register_models() -> None:
    _ = (
        User,
        GenerationJob,
        LlmUsage,
        AuditEvent,
        WorkerHeartbeat,
        Graph,
        Concept,
        ConceptRevision,
        LearningObjective,
        ObjectiveRevision,
        Edge,
        EdgeRevision,
        GraphOverlay,
        GraphRelease,
        ReleaseConcept,
        ReleaseEdge,
        SourceDocument,
        SourceClaim,
        LearningGoal,
        GoalGraph,
        Trajectory,
        TrajectoryRelease,
        TrajectoryStep,
        LearningActivity,
        ActivityObjective,
        LearningSession,
        AssessmentAttempt,
        MasteryEvidence,
        LearnerObjectiveState,
        ReviewItem,
        ReviewEvent,
        GraphChangeProposal,
        ConceptMapping,
        ObjectiveMapping,
        MigrationRun,
        MigrationItem,
    )
