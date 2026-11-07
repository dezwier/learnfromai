# ADR 001 — Immutable graph releases and personal overlays

Published concept, objective, and edge revisions are insert-only. A `graph_releases` row is a membership snapshot plus a SHA-256 checksum of those revision ids. The active shared pointer lives on `graphs.active_release_id` and moves inside a transaction that locks the graph row. A stale `base_release_id` returns `409 GRAPH_STALE`.

A personal overlay is a separate release chain (`graph_overlays.active_private_release_id`). Accepting a proposal into an overlay does not move the shared pointer. Rollback creates a newer release aimed at older revisions.

This adapts Mesozoica's publish lock and checksum, and drops the singleton release row.
