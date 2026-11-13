import os

os.environ["DATABASE_URL"] = "postgresql+psycopg://desiredewaele@localhost:5432/adaptive_mastery_test"
os.environ["SECRET_KEY"] = "test-secret-key-adaptive-mastery-32b"
os.environ["ENVIRONMENT"] = "test"
os.environ["LLM_PROVIDER"] = "fake"
os.environ["LLM_DAILY_TOKENS_USER_LIMIT"] = "1000000"
os.environ["SENTRY_DSN"] = ""

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
                "TRUNCATE TABLE knowledge_request_nodes, knowledge_requests, knowledge_edges, "
                "knowledge_nodes, knowledge_category_edges, knowledge_categories, "
                "extend_requests, llm_usage, generation_job_watchers, generation_jobs, edges, concepts, graphs, "
                "worker_heartbeats, users RESTART IDENTITY CASCADE"
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
