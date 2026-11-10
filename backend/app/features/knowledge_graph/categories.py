"""Compatibility shim. Prefer graph.load_knowledge_graph."""

from app.features.knowledge_graph.graph import load_knowledge_graph

__all__ = ["load_knowledge_graph"]
