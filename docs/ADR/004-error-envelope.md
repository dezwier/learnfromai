# ADR 004 — Error envelope

API errors use `{ "code", "message", "details" }`. Validation failures use `VALIDATION_ERROR`. Graph conflicts use `GRAPH_STALE`, `INVALID_GRAPH`, and `MIGRATION_PENDING`. Quota uses `RATE_LIMITED`. Model failure uses `GENERATION_UNAVAILABLE`.

This does not match Mesozoica's `{detail, type}` body. The spec's envelope is the contract for this app.
