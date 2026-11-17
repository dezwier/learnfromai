"""Shared LLM neighborhood expand + merge into one knowledge universe."""

from __future__ import annotations

from app.features.platform.neighborhood_llm import BUCKETS, get_neighborhood_llm, parse_uuid

from app.features.knowledge_graph.neighborhood.constants import (
    BUCKET_RELATION,
    INVERSE,
    KIND_FOR_RELATION,
    NEAR_CANDIDATE_LIMIT,
    RELATION_ACQUAINTANCE,
    RELATION_CHILD,
    RELATION_PARENT,
    RELATION_SIBLING,
    is_complete,
    relation_counts,
    set_progress,
)
from app.features.knowledge_graph.neighborhood.dedupe import consolidate_near_duplicates
from app.features.knowledge_graph.neighborhood.expand import expand_neighborhood
from app.features.knowledge_graph.neighborhood.resolve_link import (
    _upsert_named,
    ensure_focus_node,
)
from app.features.knowledge_graph.neighborhood.subgraph import build_subgraph

__all__ = [
    "BUCKETS",
    "BUCKET_RELATION",
    "INVERSE",
    "KIND_FOR_RELATION",
    "NEAR_CANDIDATE_LIMIT",
    "RELATION_ACQUAINTANCE",
    "RELATION_CHILD",
    "RELATION_PARENT",
    "RELATION_SIBLING",
    "_upsert_named",
    "build_subgraph",
    "consolidate_near_duplicates",
    "ensure_focus_node",
    "expand_neighborhood",
    "get_neighborhood_llm",
    "is_complete",
    "parse_uuid",
    "relation_counts",
    "set_progress",
]
