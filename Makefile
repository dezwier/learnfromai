BACKEND=backend
FLUTTER=flutter
PY=$(BACKEND)/.venv/bin

.PHONY: backend-install backend-test backend-run worker migrate seed flutter-test flutter-analyze deploy-api deploy-worker deploy-web

backend-install:
	python3.13 -m venv $(BACKEND)/.venv
	$(PY)/pip install -e "$(BACKEND)[dev]"

backend-test:
	cd $(BACKEND) && .venv/bin/pytest

backend-run:
	cd $(BACKEND) && .venv/bin/uvicorn app.main:app --reload --port 8000

worker:
	cd $(BACKEND) && .venv/bin/python -m app.workers

migrate:
	cd $(BACKEND) && .venv/bin/alembic upgrade head

seed:
	cd $(BACKEND) && .venv/bin/python -m scripts.seed

flutter-test:
	cd $(FLUTTER) && flutter test

flutter-analyze:
	cd $(FLUTTER) && flutter analyze

deploy-api:
	railway up backend --path-as-root --service api --environment production --detach -m "Deploy Adaptive Mastery API"

deploy-worker:
	railway up backend --path-as-root --service worker --environment production --detach -m "Deploy Adaptive Mastery worker"

deploy-web:
	railway up flutter --path-as-root --service web --environment production --project adaptive-mastery --detach -m "Deploy Adaptive Mastery web"
