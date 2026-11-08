from __future__ import annotations

from sqlmodel import Session, select

from app.features.knowledge_graph.models import Graph


def shared_graph(session: Session) -> Graph:
    """The one graph everyone extends."""
    existing = session.exec(select(Graph).where(Graph.slug == "knowledge")).first()
    if existing is not None:
        return existing
    graph = Graph(slug="knowledge", title="Knowledge")
    session.add(graph)
    session.flush()
    return graph
