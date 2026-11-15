# Adaptive Mastery

A Flutter client and a FastAPI service for one shared knowledge graph. Sign in, look at the nodes and edges, and extend the graph. Past extend requests from every user stay on the graph.

The product contract is `docs/SPEC.md`. Architecture is in `docs/ARCHITECTURE.md`.

## Learning modules (target design)

Four layers share one graph. Trajectory and content do not talk to each other directly — they both read **learner state**, and sparse events decide what to replan or regenerate.

![Learning modules: universe, learner state, trajectory, and content](docs/images/learning-modules.jpg)

### Concrete walkthrough

| Step | What happens | Example |
|------|----------------|---------|
| Request | Focus / expand into the shared universe | Goal node: **Transformers** |
| Universe | Neighborhood already has (or grows) related topics | Embeddings, Attention, Softmax, Positional encoding, … |
| Trajectory | Planner picks a short path from known → goal | `Embeddings → Softmax → Dot-product attention → Multi-head → Transformers` |
| Learn | Generate only when the user opens a tile | Open **Attention**: 1 screen explanation, 1 worked QKV example, 1 comprehension check |
| Retain | Schedule retrieval separately from “reading” | Next day: cloze on “query vs key”; compare attention vs convolution |
| Feedback | Typed signal → patch state → maybe replan | Fail check on Attention → insert **Dot product** before it; bump Attention content to a simpler band — do **not** regenerate the whole path |

UI lenses on the same graph: **canvas** = explore universe, **path overlay / queue** = trajectory, **tile sheet** = learn + retain.

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
```

`make backend-test`, `make worker`, `make migrate`, and `make seed` wrap the same commands. Seed creates the empty shared graph when it is missing. The worker applies extend requests. Tests use `LLM_PROVIDER=fake`.

A real worker calls Gemini and/or OpenAI depending on each user's **Settings → App → AI provider** switch (default Gemini). Configure both keys on the worker so either side of the switch works:

- `GOOGLE_GEMINI_API_KEY` (+ optional `GEMINI_MODEL`, `GEMINI_IMAGE_MODEL=gemini-3.1-flash-lite-image`)
- `OPENAI_API_KEY` (+ optional `OPENAI_MODEL=gpt-4o-mini`, `OPENAI_IMAGE_MODEL=gpt-image-2.5-flare`, `OPENAI_IMAGE_QUALITY=low`)
- `LLM_PROVIDER=gemini` as the server default when a user has not chosen

See [LLM provider setup](#llm-provider-setup) below.

## Flutter

```bash
cd flutter
flutter pub get
flutter analyze
flutter test
flutter run -d chrome --dart-define=API_BASE_URL=http://localhost:8000
```

The same Flutter UI is served at https://web-production-82d46b.up.railway.app. It is a release build of this client, with `API_BASE_URL` set to the API. `make deploy-web` uploads `flutter/` and Railway builds it.

Sign-in uses this app's `learnfromai` Firebase project, including the Adaptive Mastery web app. Do not reuse an Archipelago, Mesozoica, or CycleTravels Firebase app. For the Auth emulator, run the emulator and set `FIREBASE_AUTH_EMULATOR_HOST` on the API.

The API JWT is stored with `flutter_secure_storage`.

## Tests

```bash
cd backend && .venv/bin/ruff check app tests scripts && .venv/bin/pytest
cd flutter && flutter analyze && flutter test
```

Backend tests use database `adaptive_mastery_test` on local Postgres. `tests/test_alembic_empty.py` upgrades an empty `adaptive_mastery_alembic` database and checks that an old published release flattens into nodes and edges.

## Deploy

The Railway project is `adaptive-mastery` (`1e9dd5da-db31-413a-a5d6-6924ce1d04f7`) in the production environment. It has its own Postgres, API, worker, and web service. It does not share a project or variables with the other apps.

The API is at https://api-production-b1075.up.railway.app and `GET /health` returns `{"status":"ok"}`. Alembic runs once, as the API pre-deploy command. The worker does not run migrations. The worker uses Gemini and/or OpenAI based on user preference. A new `SECRET_KEY` was generated for this project.

```bash
make deploy-api
make deploy-worker
railway ssh --service api -- python -m scripts.seed
```

`railway up` is run from `backend` with `--path-as-root`, so the image build matches `backend/Dockerfile`. The API start command is `sh -c "uvicorn app.main:app --host 0.0.0.0 --port $PORT"` because Railway does not expand `$PORT` otherwise.

## LLM provider setup

What the code already does: App settings switch (Gemini / ChatGPT), preference API, OpenAI + Gemini adapters (`gpt-4o-mini` by default), shared topic image generation (`gemini-3.1-flash-lite-image` / `gpt-image-2.5-flare`), shared prompts, and spend capping for both.

What you need to do:

1. Create an OpenAI API key at https://platform.openai.com/api-keys and add billing/credits.
2. On the Railway **worker** (and API if you keep envs in sync), set:
   - `OPENAI_API_KEY=sk-...`
   - `OPENAI_MODEL=gpt-4o-mini` (optional; this is the default)
   - Keep `GOOGLE_GEMINI_API_KEY` so Gemini still works
   - Optional: `LLM_PROVIDER=gemini` as the default for users who never flipped the switch
3. Redeploy the worker after env vars change (`make deploy-worker`). Redeploy API/web if this branch is not live yet.
4. In the app: **Settings → App → AI provider → ChatGPT**, expand a neighborhood, then flip back to Gemini to confirm both paths.
5. Daily spend still hits `LLM_DAILY_SPEND_EUR_LIMIT` from recorded USD for either provider.
