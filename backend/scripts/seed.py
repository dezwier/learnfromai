from sqlmodel import Session

from app.core.db import engine
from app.features.knowledge_graph.service import seed_decision_trees
from app.model_registry import register_models


def main() -> None:
    register_models()
    with Session(engine, expire_on_commit=False) as session:
        graph = seed_decision_trees(session)
        session.commit()
        print(f"seeded {graph.slug} release {graph.active_release_id}")


if __name__ == "__main__":
    main()
