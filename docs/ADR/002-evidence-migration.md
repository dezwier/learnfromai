# ADR 002 — Objective evidence and migration

Mastery moves only when an objective mapping says the evidence still applies.

- Same objective id and same statement fingerprint: keep the state. Do not copy evidence onto itself.
- Same id with a new fingerprint: `needs_reassessment`. Old attempts stay attached to the revision they used.
- Explicit `remap` or `preserve` onto a different objective: insert new evidence rows with `migration_origin_id`. Deduplicate by attempt id and dimension on the target.
- Unmapped new objectives stay unknown. Parent estimates are not copied.
- One review schedule moves to at most one equivalent item. Splits do not clone it.

The migration key is `(user_id, from_release_id, to_release_id)`. A retry continues unfinished items and the unique index on `(user_id, objective_id, migration_origin_id)` blocks a second copy. The goal pointer changes only after the run succeeds. Open sessions keep the trajectory and release they started with.
