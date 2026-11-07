# AGENTS.md

Adaptive Mastery is a Flutter client and a FastAPI service. Read `docs/SPEC.md` before changing learning behavior.

- Backend features live under `backend/app/features/<name>/`. Routers stay thin. Domain rules for the graph, planner, mastery, and migration do not import FastAPI.
- Do not edit published revisions or historical attempts in place. Graph changes create a new release and a migration run.
- Loading UI uses `PulsePlaceholder` at the size of the finished block.
- Do not copy credentials, Firebase app ids, or Railway projects from Archipelago, Mesozoica, or CycleTravels.
