import os
import subprocess
import sys


def test_alembic_upgrade_on_empty_database():
    database = "adaptive_mastery_alembic"
    subprocess.check_call(["psql", "-d", database, "-c", "DROP SCHEMA public CASCADE; CREATE SCHEMA public;"])
    env = os.environ.copy()
    env["DATABASE_URL"] = f"postgresql+psycopg://desiredewaele@localhost:5432/{database}"
    env["SECRET_KEY"] = "test-secret-key-adaptive-mastery-32b"
    env["LLM_PROVIDER"] = "fake"
    subprocess.check_call([sys.executable, "-m", "alembic", "upgrade", "head"], env=env)
