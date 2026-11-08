from sqlmodel import Session

from app.core.db import engine
from app.features.knowledge_graph.service import shared_graph
from app.model_registry import register_models


def main() -> None:
    register_models()
    with Session(engine, expire_on_commit=False) as session:
        graph = shared_graph(session)
        session.commit()
        print(f"seeded {graph.slug}")


if __name__ == "__main__":
    main()
