"""Import every table model so SQLModel.metadata is complete."""

from app.features.accounts.models import User
from app.features.content.models import KnowledgeBit
from app.features.knowledge_graph.node_models import (
    KnowledgeEdge,
    KnowledgeNode,
    KnowledgeRequest,
    KnowledgeRequestNode,
)
from app.features.node_image.pack_models import KnowledgePackImage
from app.features.platform.models import (
    GenerationJob,
    GenerationJobWatcher,
    LlmUsage,
    WorkerHeartbeat,
)
from app.features.ranking.models import CronRun, RankingConfig
from app.features.reviews.models import UserPackReview
from app.features.user_events.models import UserTopicEvent


def register_models() -> None:
    _ = (
        User,
        GenerationJob,
        GenerationJobWatcher,
        LlmUsage,
        WorkerHeartbeat,
        KnowledgeNode,
        KnowledgeEdge,
        KnowledgeRequest,
        KnowledgeRequestNode,
        KnowledgeBit,
        KnowledgePackImage,
        UserTopicEvent,
        UserPackReview,
        CronRun,
        RankingConfig,
    )
