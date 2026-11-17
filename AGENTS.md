# AGENTS.md

Adaptive Mastery is a Flutter client and a FastAPI service. Read `docs/SPEC.md` before changing the graph.

- Backend features live under `backend/app/features/<name>/`. Routers stay thin. Graph merge rules do not import FastAPI.
- There is one shared graph of nodes and edges. An extend merges new nodes and edges into that graph. Do not add a second graph, proposals, or private overlays.
- Loading UI uses `PulsePlaceholder` at the size of the finished block.
- Do not copy credentials, Firebase app ids, or Railway projects from Archipelago, Mesozoica, or CycleTravels.

## File size

Soft target **~400 lines** for production `.dart` / `.py`. Soft ceiling **~800** only for true orchestration (`graph_screen`, `GraphController`)—extract before growing further. One primary responsibility per file.

Knowledge graph layout:

```text
flutter/lib/features/knowledge_graph/
  graph_screen.dart              # orchestration only
  graph_controller.dart
  models.dart
  layout/                        # placement, geometry, title_wrap
  ui/                            # graph_view, topic_detail, search, trail, jobs, learn_sheet

backend/app/features/knowledge_graph/
  neighborhood/                  # expand, dedupe, resolve_link, subgraph
```

New UI goes under `ui/`, not into `graph_screen.dart`. Prefer the `learn_sheet` pattern (small public API + Provider). Exempt Alembic migrations and generated code.
