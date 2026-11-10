"""Compatibility shim. Prefer graph.focus_or_enqueue."""

from app.features.knowledge_graph.graph import focus_or_enqueue, load_knowledge_graph

__all__ = ["focus_or_enqueue", "load_knowledge_graph"]
