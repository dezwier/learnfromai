import os

os.environ["DATABASE_URL"] = "postgresql+psycopg://desiredewaele@localhost:5432/adaptive_mastery_test"
os.environ["SECRET_KEY"] = "test-secret-key-adaptive-mastery-32b"
os.environ["ENVIRONMENT"] = "test"
os.environ["LLM_PROVIDER"] = "fake"
os.environ["LLM_DAILY_TOKENS_USER_LIMIT"] = "1000000"
os.environ["SENTRY_DSN"] = ""
os.environ["GRAPH_FRESHNESS_CHECK_ENABLED"] = "false"

import pytest
from alembic.config import Config
from fastapi.testclient import TestClient
from sqlalchemy import text
from sqlmodel import Session

from alembic import command
from app.core.db import engine
from app.core.security import create_access_token
from app.features.accounts.models import User
from app.model_registry import register_models

register_models()


@pytest.fixture(scope="session", autouse=True)
def migrated():
    config = Config("alembic.ini")
    command.upgrade(config, "head")


@pytest.fixture(autouse=True)
def clean_db():
    with Session(engine, expire_on_commit=False) as session:
        session.exec(
            text(
                "TRUNCATE TABLE review_events, review_items, mastery_evidence, learner_objective_states, "
                "migration_items, migration_runs, objective_mappings, concept_mappings, assessment_attempts, "
                "activity_objectives, learning_activities, learning_sessions, trajectory_steps, trajectory_releases, "
                "trajectories, goal_graphs, learning_goals, source_claims, source_documents, release_edges, "
                "release_concepts, graph_change_proposals, graph_releases, graph_overlays, objective_revisions, "
                "learning_objectives, concept_revisions, concepts, edge_revisions, edges, graphs, llm_usage, "
                "generation_jobs, audit_events, worker_heartbeats, users RESTART IDENTITY CASCADE"
            )
        )
        session.commit()
    yield


@pytest.fixture
def session():
    with Session(engine, expire_on_commit=False) as db:
        yield db


@pytest.fixture
def client():
    from app.main import app

    return TestClient(app)


@pytest.fixture
def user(session: Session) -> User:
    row = User(firebase_uid="ada", email="ada@example.com", display_name="Ada", timezone="Europe/Brussels")
    session.add(row)
    session.commit()
    session.refresh(row)
    return row


@pytest.fixture
def other_user(session: Session) -> User:
    row = User(firebase_uid="grace", email="grace@example.com", display_name="Grace", timezone="UTC")
    session.add(row)
    session.commit()
    session.refresh(row)
    return row


@pytest.fixture
def auth(user: User) -> dict:
    return {"Authorization": f"Bearer {create_access_token(user.id)}"}


@pytest.fixture
def other_auth(other_user: User) -> dict:
    return {"Authorization": f"Bearer {create_access_token(other_user.id)}"}
