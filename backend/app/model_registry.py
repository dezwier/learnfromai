"""Import every table model so SQLModel.metadata is complete."""

from app.features.accounts.models import User
from app.features.content.models import KnowledgeBit
from app.features.graph_extend.models import ExtendRequest
from app.features.knowledge_graph.category_models import KnowledgeCategory, KnowledgeCategoryEdge
from app.features.knowledge_graph.models import Concept, Edge, Graph
from app.features.knowledge_graph.node_models import (
    KnowledgeEdge,
    KnowledgeNode,
    KnowledgeRequest,
    KnowledgeRequestNode,
)
from app.features.platform.models import (
    GenerationJob,
    GenerationJobWatcher,
    LlmUsage,
    WorkerHeartbeat,
)
from app.features.ranking.models import CronRun
from app.features.reviews.models import UserPackReview
from app.features.user_events.models import UserTopicEvent


def register_models() -> None:
    _ = (
        User,
        GenerationJob,
        GenerationJobWatcher,
        LlmUsage,
        WorkerHeartbeat,
        Graph,
        Concept,
        Edge,
        ExtendRequest,
        KnowledgeCategory,
        KnowledgeCategoryEdge,
        KnowledgeNode,
        KnowledgeEdge,
        KnowledgeRequest,
        KnowledgeRequestNode,
        KnowledgeBit,
        UserTopicEvent,
        UserPackReview,
        CronRun,
    )
