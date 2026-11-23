import os
import subprocess
import sys

from sqlalchemy import create_engine, text


def _reset(database: str) -> None:
    subprocess.check_call(
        [
            "psql",
            f"postgresql://desiredewaele@localhost:5432/{database}",
            "-c",
            "DROP SCHEMA public CASCADE; CREATE SCHEMA public;",
        ]
    )


def _alembic(database: str, revision: str) -> None:
    env = os.environ.copy()
    env["DATABASE_URL"] = f"postgresql+psycopg://desiredewaele@localhost:5432/{database}"
    env["SECRET_KEY"] = "test-secret-key-adaptive-mastery-32b"
    env["LLM_PROVIDER"] = "fake"
    subprocess.check_call([sys.executable, "-m", "alembic", "upgrade", revision], env=env)


def _engine(database: str):
    return create_engine(f"postgresql+psycopg://desiredewaele@localhost:5432/{database}")


def test_alembic_upgrade_on_empty_database():
    database = "adaptive_mastery_alembic"
    _reset(database)
    _alembic(database, "head")
    with _engine(database).connect() as connection:
        tables = {row[0] for row in connection.execute(text("SELECT tablename FROM pg_tables WHERE schemaname = 'public'"))}
    assert "knowledge_nodes" in tables
    assert "knowledge_edges" in tables
    assert "knowledge_requests" in tables
    assert "knowledge_request_nodes" in tables
    assert "knowledge_bits" in tables
    assert "user_topic_events" in tables
    assert "users" in tables
    assert "generation_jobs" in tables
    assert "concepts" not in tables
    assert "edges" not in tables
    assert "graphs" not in tables
    assert "extend_requests" not in tables
    assert "knowledge_categories" not in tables
    assert "knowledge_category_edges" not in tables
    assert "learning_goals" not in tables
    assert "graph_releases" not in tables
    assert "trajectories" not in tables
    with _engine(database).connect() as connection:
        cols = {
            row[0]
            for row in connection.execute(
                text("SELECT column_name FROM information_schema.columns WHERE table_name = 'knowledge_nodes'")
            )
        }
    assert "id" in cols
    assert "name_key" in cols
    assert "qid" not in cols
