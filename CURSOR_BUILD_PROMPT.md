# Cursor build prompt — Adaptive Mastery

Build the application specified in `MASTER_ANY_TOPIC_SPEC.md` (place this file at `docs/SPEC.md` in the new repo). Treat it as the product and engineering acceptance contract, not general inspiration.

Before editing code:
1. Inspect the local Git reference repos `archipelago`, `cycletravels`, and `mesozoica` wherever they are checked out. Read `AGENTS.md`, relevant architecture docs, current Firebase auth flow, Flutter HTTP/token handling, Gemini transport/structured output and usage accounting, FastAPI DB/Alembic setup, Railway manifests, and existing test patterns. If a repo is absent, note it and do not invent details.
2. Create `docs/REUSE_AUDIT.md` mapping exact existing files and commit hashes to what will be reused/adapted, with reasons. Keep these repos unchanged.
3. Start a new standalone Flutter + FastAPI + PostgreSQL + Railway project, keeping credentials, Firebase app, DB, Railway service and app IDs isolated.
4. Write `docs/ARCHITECTURE.md` and an initial ADR about immutable graph releases, personal overlays, and objective-level mastery evidence/migration.

Implement in phases and work through each phase as far as possible: (0) project/auth/worker, (1) versioned graph, (2) goals + deterministic trajectories, (3) AI learning/assessment + FSRS reviews + evidence-backed mastery, (4) user-driven and knowledge-driven graph revisions with mastery migration, (5) operational hardening. Build real Flutter screens and API integrations; never substitute placeholder business logic for critical functionality.

Non-negotiable invariants:
- Published revisions immutable; graph release pinned on every trajectory and learning session.
- Historical attempts/evidence never rewritten or deleted by graph changes.
- Every semantic graph change has a typed concept/objective mapping and a mastery migration preview; split/merge transfers **only** applicable objective evidence.
- New/unknown objectives do not inherit parent mastery; preserve existing FSRS state only for equivalent review items.
- LLMs propose/generate/grade with schema validation; deterministic services own graph integrity, planning, scheduling, transactions and version activation.
- Auth checks on every user-specific endpoint; idempotent jobs and retries; new Railway environment with no production credential copying.

For each phase: implement code, add migration(s), real tests, run tests/static analysis, report what passes and what remains. Do not change unrelated files in any reference repo. If a decision is unspecified, choose the simplest design satisfying the invariants and write it down. Finish by giving exact local start/test/deploy commands and a demonstrable end-to-end flow.
