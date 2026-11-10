import os
import subprocess
import sys
from uuid import uuid4

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
    assert "concepts" in tables
    assert "edges" in tables
    assert "extend_requests" in tables
    assert "knowledge_categories" in tables
    assert "knowledge_category_edges" in tables
    assert "knowledge_nodes" in tables
    assert "knowledge_edges" in tables
    assert "knowledge_requests" in tables
    assert "knowledge_request_nodes" in tables
    assert "users" in tables
    assert "generation_jobs" in tables
    assert "learning_goals" not in tables
    assert "graph_releases" not in tables
    assert "trajectories" not in tables


def test_alembic_flattens_a_published_release():
    database = "adaptive_mastery_alembic"
    _reset(database)
    _alembic(database, "a1c0e5b79d22")
    graph_id = uuid4()
    concept_id = uuid4()
    private_id = uuid4()
    revision_id = uuid4()
    private_revision_id = uuid4()
    edge_id = uuid4()
    edge_revision_id = uuid4()
    release_id = uuid4()
    with _engine(database).begin() as connection:
        connection.execute(
            text(
                """
                INSERT INTO graphs (id, slug, title, visibility, created_at)
                VALUES (:id, 'knowledge', 'Knowledge', 'shared', NOW())
                """
            ),
            {"id": graph_id},
        )
        connection.execute(
            text(
                """
                INSERT INTO concepts (id, canonical_key, origin_graph_id, scope, created_at)
                VALUES (:id, 'dinosaurs', :graph_id, 'domain', NOW()),
                       (:private_id, 'private-note', :graph_id, 'domain', NOW())
                """
            ),
            {"id": concept_id, "private_id": private_id, "graph_id": graph_id},
        )
        connection.execute(
            text(
                """
                INSERT INTO concept_revisions (
                    id, concept_id, revision_no, title, summary, knowledge_type, semantic_fingerprint,
                    change_kind, source_status, status, creator, created_at
                )
                VALUES
                    (:id, :concept_id, 1, 'Dinosaurs', 'Ancient reptiles', 'timeless_foundation', 'fp', 'initial', 'source_pending', 'published', 'system', NOW()),
                    (:private_revision_id, :private_id, 1, 'Private note', 'Hidden', 'timeless_foundation', 'fp2', 'initial', 'source_pending', 'published', 'system', NOW())
                """
            ),
            {
                "id": revision_id,
                "concept_id": concept_id,
                "private_revision_id": private_revision_id,
                "private_id": private_id,
            },
        )
        connection.execute(
            text(
                """
                INSERT INTO edges (id, graph_id, created_at) VALUES (:id, :graph_id, NOW())
                """
            ),
            {"id": edge_id, "graph_id": graph_id},
        )
        connection.execute(
            text(
                """
                INSERT INTO edge_revisions (
                    id, edge_id, revision_no, from_concept_id, to_concept_id, type, is_primary_parent, created_at
                )
                VALUES (:id, :edge_id, 1, :concept_id, :concept_id, 'related', false, NOW())
                """
            ),
            {"id": edge_revision_id, "edge_id": edge_id, "concept_id": concept_id},
        )
        connection.execute(
            text(
                """
                INSERT INTO graph_releases (id, graph_id, version, checksum, status, published_at)
                VALUES (:id, :graph_id, 1, 'abc', 'published', NOW())
                """
            ),
            {"id": release_id, "graph_id": graph_id},
        )
        connection.execute(
            text("UPDATE graphs SET active_release_id = :release_id WHERE id = :graph_id"),
            {"release_id": release_id, "graph_id": graph_id},
        )
        connection.execute(
            text(
                """
                INSERT INTO release_concepts (release_id, concept_id, concept_revision_id)
                VALUES (:release_id, :concept_id, :revision_id)
                """
            ),
            {"release_id": release_id, "concept_id": concept_id, "revision_id": revision_id},
        )
        connection.execute(
            text(
                """
                INSERT INTO release_edges (release_id, edge_id, edge_revision_id)
                VALUES (:release_id, :edge_id, :edge_revision_id)
                """
            ),
            {"release_id": release_id, "edge_id": edge_id, "edge_revision_id": edge_revision_id},
        )

    _alembic(database, "head")
    with _engine(database).connect() as connection:
        titles = {row[0] for row in connection.execute(text("SELECT title FROM concepts"))}
        edge = connection.execute(text("SELECT from_concept_id, to_concept_id, type FROM edges")).one()
        tables = {row[0] for row in connection.execute(text("SELECT tablename FROM pg_tables WHERE schemaname = 'public'"))}
    assert titles == {"Dinosaurs"}
    assert edge[2] == "related"
    assert "graph_releases" not in tables
    assert "extend_requests" in tables
