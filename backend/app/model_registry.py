"""Import every table model so SQLModel.metadata is complete."""

from app.features.accounts.models import User
from app.features.graph_extend.models import ExtendRequest
from app.features.knowledge_graph.models import Concept, Edge, Graph
from app.features.platform.models import GenerationJob, LlmUsage, WorkerHeartbeat


def register_models() -> None:
    _ = (
        User,
        GenerationJob,
        LlmUsage,
        WorkerHeartbeat,
        Graph,
        Concept,
        Edge,
        ExtendRequest,
    )
