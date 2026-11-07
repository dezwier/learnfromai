# Adaptive Mastery

A Flutter client and a FastAPI service for learning one topic through a versioned concept graph, a deterministic study plan, evidence-backed mastery, and scheduled review.

The product contract is `docs/SPEC.md`. Architecture and the data model are in `docs/ARCHITECTURE.md`. Reused patterns are listed in `docs/REUSE_AUDIT.md`.

## Local API

Postgres is required. Docker Compose publishes Postgres 16 on port **5433** so it does not collide with a Postgres already listening on 5432:

```bash
docker compose up -d
cd backend
python3.13 -m venv .venv
.venv/bin/pip install -e ".[dev]"
DATABASE_URL=postgresql+psycopg://mastery:mastery@localhost:5433/adaptive_mastery \
  .venv/bin/alembic upgrade head
LLM_PROVIDER=fake .venv/bin/uvicorn app.main:app --reload --port 8000
```

On this machine, Homebrew Postgres on port 5432 also works. Create `adaptive_mastery` and point `DATABASE_URL` at `postgresql+psycopg://desiredewaele@localhost:5432/adaptive_mastery`.

In another shell, from `backend`:

```bash
LLM_PROVIDER=fake .venv/bin/python -m app.workers
LLM_PROVIDER=fake .venv/bin/python -m scripts.seed
LLM_PROVIDER=fake .venv/bin/python -m scripts.demo_flow
```

`make backend-test`, `make worker`, `make migrate`, `make seed`, and `make demo` wrap the same commands. The demo uses `LLM_PROVIDER=fake` and makes no paid model calls. It signs in a local demo user, reuses the Decision Trees graph, answers the diagnostic as unknown, studies the next step, scores a retrieval item, previews an expansion, and activates it as a personal overlay.

## Flutter

```bash
cd flutter
flutter pub get
flutter analyze
flutter test
flutter run -d chrome --dart-define=API_BASE_URL=http://localhost:8000
```

Sign-in needs a Firebase project that belongs to this app. `lib/core/firebase/firebase_options.dart` is a placeholder (`adaptive-mastery-dev`). Replace it with `flutterfire configure` for a new project. Do not reuse an Archipelago, Mesozoica, or CycleTravels Firebase app. For the Auth emulator, run the emulator and set `FIREBASE_AUTH_EMULATOR_HOST` on the API.

The API JWT is stored with `flutter_secure_storage`.

## Tests

```bash
cd backend && .venv/bin/ruff check app tests scripts && .venv/bin/pytest
cd flutter && flutter analyze && flutter test
```

Backend integration tests use database `adaptive_mastery_test` on local Postgres. `tests/test_alembic_empty.py` upgrades an empty `adaptive_mastery_alembic` database.

Latest local run: ruff clean, **31** pytest tests passed, `flutter analyze` reported no issues, **8** Flutter tests passed. The Decision Trees demo printed a next step of Decision Trees, a retrieval score of 1.0, a preview of 4 preserved and 2 new objectives, and a succeeded personal activation.

## Deploy

The Railway project is `adaptive-mastery` (`1e9dd5da-db31-413a-a5d6-6924ce1d04f7`) in the production environment. It has its own Postgres, API, and worker. It does not share a project or variables with the other apps.

The API is at https://api-production-b1075.up.railway.app and `GET /health` returns `{"status":"ok"}`. Alembic runs once, as the API pre-deploy command. The worker does not run migrations. `LLM_PROVIDER` is `fake` until a Gemini key is added. A new `SECRET_KEY` was generated for this project.

```bash
make deploy-api
make deploy-worker
railway ssh --service api -- python -m scripts.seed
```

`railway up` is run from `backend` with `--path-as-root`, so the image build matches `backend/Dockerfile`. The API start command is `sh -c "uvicorn app.main:app --host 0.0.0.0 --port $PORT"` because Railway does not expand `$PORT` otherwise.

## Limits

Shared high-impact publish fails without a retrieved source. The Decision Trees seed is labeled `source_pending` and is a fixture, not a fact-checked corpus. A personal overlay may activate while provisional and the client labels that preview. A missing Gemini key returns `503 GENERATION_UNAVAILABLE` and does not invent a lesson. Cached activities still open when generation is down. Free-text grading uses the model; with `LLM_PROVIDER=fake`, keyword and multiple-choice grading stay in the request. There is no chat tutor, payment, or social feed.
