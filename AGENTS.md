# AGENTS.md

Adaptive Mastery is a Flutter client and a FastAPI service. Read `docs/SPEC.md` before changing the graph.

- Backend features live under `backend/app/features/<name>/`. Routers stay thin. Graph merge rules do not import FastAPI.
- There is one shared graph of nodes and edges. An extend merges new nodes and edges into that graph. Do not add a second graph, proposals, or private overlays.
- Loading UI uses `PulsePlaceholder` at the size of the finished block.
- Do not copy credentials, Firebase app ids, or Railway projects from Archipelago, Mesozoica, or CycleTravels.
