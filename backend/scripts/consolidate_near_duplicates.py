"""One-shot / ops helper: merge same_topic knowledge nodes in the shared graph."""

from __future__ import annotations

from sqlmodel import Session

from app.core.db import engine
from app.features.knowledge_graph.neighborhood import consolidate_near_duplicates
from app.model_registry import register_models


def main() -> None:
    register_models()
    with Session(engine) as session:
        merges = consolidate_near_duplicates(session)
        session.commit()
    print(f"merged={merges}")


if __name__ == "__main__":
    main()
