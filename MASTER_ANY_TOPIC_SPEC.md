# Adaptive Mastery — implementation specification for Cursor

**Status:** Build-ready product/engineering spec (v1.0)  
**Target stack:** Flutter (iOS, Android, web), FastAPI (Python), PostgreSQL, Railway, Firebase Auth, existing Gemini/LLM integration  
**Repo policy:** Create a **new standalone repository**, using existing projects as read-only implementation references. Do not alter Archipelago/Talivo, Mesozoica, or CycleTravels unless explicitly requested.  
**Working name:** Adaptive Mastery (replace later).

> **Agent directive:** Build a working vertical slice, not a set of mock screens or an autonomous multi-agent framework. Read this entire specification. Before coding, inspect local reference repositories and their `AGENTS.md` files, identify reusable implementation patterns, then write a short `docs/REUSE_AUDIT.md` mapping references to new files. Follow the phased build order and acceptance tests below. Make pragmatic choices when details are unspecified; document them in ADRs. Never copy secrets, production credentials, live user data, app identifiers, or unrelated business logic.

## 0. Product definition

An app in which a learner states **any topic** and a desired level of mastery. The application creates or reuses a hierarchical, versioned knowledge graph; diagnoses existing knowledge; selects a personalized trajectory; teaches and tests concepts using AI-generated activities; schedules retrieval-based reviews; maintains an evidence-backed mastery model; and replans after assessment or graph changes.

**Canonical feedback loop:**

`Versioned Knowledge Graph → Personal Goal + Trajectory → Learn / Retrieve / Apply → Evidence + Mastery + Retention → Replan Trajectory`

Two distinct graph-change loops feed this system:

1. **User-driven expansion**: a user opens a missing branch or requests a new subtopic, triggering provisional concept generation and graph expansion.
2. **Knowledge-driven maintenance**: validated new evidence, outdated software/API examples, corrections, user reports, or a scheduled source review trigger a proposed graph/content revision.

Every graph change must have an explicit **mastery migration plan**, including a no-op migration when no mastered capability changes.

### Product principles

1. **Hierarchy first, graph underneath.** Render an intuitive domain → topic → concept → atomic objective outline, while storing DAG relationships (`contains`, `prerequisite`, `related`, `part_of`, `supersedes`). The user navigates a hierarchy and can discover cross-links.
2. **A concept is not its lesson.** Knowledge identity, semantic objectives, educational content, assessment evidence, and each learner's mastery have different lifecycles.
3. **Evidence over completion.** Reading a lesson does not imply mastery. Demonstrated recall, explanation, transfer, and application do.
4. **Dynamic but reproducible.** Published graph releases and educational artifacts are immutable. An old assessment must always be explainable against the exact concept revision and rubric it used.
5. **Algorithmic learning state.** LLMs generate, explain, and grade carefully scoped free-text answers; deterministic software owns graph integrity, versioning, scheduling, migration, and trajectory decisions.
6. **Grounded claims.** AI-created factual material has cited, retrievable sources and a validation status. A source check is not equivalent to fact-checking all assertions.

### MVP user journeys

- **Start:** Sign in → enter “I want to master [topic] for [goal]” → choose desired depth and weekly time → graph draft generated/reused → quick diagnostic → first personal trajectory.
- **Learn:** Open next concept → short explanation, example, check-for-understanding, active-recall and application tasks → submit → receive actionable feedback → mastery updates → next recommendation.
- **Retain:** Daily review queue with due concept/objective-aligned prompts, not only vocabulary flashcards → submit answer → review scheduler updates future due date.
- **Explore:** Browse hierarchical map, expand branch, inspect prerequisite edges, request a missing branch, and see proposed additions.
- **Change goals:** Switch or add a new goal, e.g. from ML to robotics. Keep mastery history; produce a new trajectory using existing knowledge and any newly expanded branches.
- **Graph evolves:** Receive a transparent “Knowledge updated” notice with old/new diff and whether existing mastery is preserved, reassessed, or now partially uncovered.

**Explicit non-goals for MVP:** social feed, marketplace, payment/subscriptions, fully autonomous web-wide scientific discovery, image/video generation, realtime collaborative editing, neo4j, complex reinforcement learning, guaranteed mastery scores, automatic publishing of high-risk factual claims, full offline editing, cross-app shared login or shared user DB.

---

## 1. Technology and reuse instructions

### Required stack

- **Frontend:** Flutter/Dart; feature-first modules; Provider/ChangeNotifier unless an existing, proven project-level convention strongly favors otherwise; `go_router`; native Firebase sign-in; secure token persistence (use platform-appropriate mechanism); responsive web/tablet/mobile design.
- **API:** FastAPI; Python 3.12+; Pydantic v2; SQLModel or SQLAlchemy 2 (choose one coherent standard, preferably SQLModel following Mesozoica); Alembic migrations; typed request/response models; `/api/v1` prefix.
- **Database:** PostgreSQL on Railway, `UUID` primary keys where useful, JSONB for structured payloads, indexes for graph edges and review queues. Keep graph as SQL tables/recursive queries, not a separate graph DB at MVP scale.
- **Async work:** dedicated Railway worker process and Postgres-backed jobs using `FOR UPDATE SKIP LOCKED`, lease expiry, attempts, status and idempotency; optionally swap to Redis-backed worker later. Do not run long LLM calls in request handlers.
- **Authentication:** Firebase Auth in Flutter; verify Firebase ID tokens server-side and/or exchange for existing-style API JWT; authorize resource ownership on every endpoint. Preserve one consistent pattern; do not invent a second auth stack.
- **LLM:** Gemini initially, behind a provider-neutral interface, using your existing request/JSON validation, retries, rate controls, structured output, usage metrics and redacted logging conventions.
- **Deploy/observability:** Railway API + worker + PostgreSQL; health endpoints, structured logs, Sentry integration where available; staging environment; never expose API keys to Flutter.

### Reference-repo reuse audit (required before implementation)

These files/patterns were verified in connected GitHub repositories; local copies may contain newer code. **Inspect local checkout and prefer its current implementation**:

**Archipelago / Talivo (`dezwier/archipelago`, local `git/archipelago` or equivalent):**

- `AGENTS.md` — app naming/layering rules, Flutter feature-first structure, API organization.
- `app/lib/src/core/api/api_client.dart` — bearer token transport, retries, centralized error handling.
- `app/lib/src/features/shared/providers/auth_provider.dart`, `.../data/token_storage.dart` — Flutter session handling.
- `api/app/services/auth_service/firebase.py` and `api/app/services/auth_service/` — Firebase ID-token validation, linking/login.
- `api/app/services/llm_service.py` — Gemini JSON response handling, token usage and cost accounting.
- `api/alembic/`, `api/.env.example` — migration and Railway-style configuration patterns.

**Mesozoica (`dezwier/mesozoica`, local `git/mesozoica`):**

- `AGENTS.md`, `docs/ARCHITECTURE.md`, `docs/CONTRACTS.md` — feature-first modular monolith boundaries.
- `backend/app/features/accounts/infrastructure/firebase_auth.py` — token verification.
- `backend/app/features/ingestion/infrastructure/llm/client.py` — Gemini transport and structured JSON generation.
- `backend/app/features/game_config/models_revision.py`, `models_release.py` — immutable revision + active-release pointer/transactional publishing pattern. **Adapt the pattern, not the singleton model**: this app needs one active release per graph/workspace.
- `backend/app/features/assistant/` — evidence-based AI Q&A boundary.
- `flutter/lib/core/networking/api_client.dart` — authenticated requests and token refresh coordination.
- `backend/alembic/`, `railway.toml` — migration/deployment conventions.

**CycleTravels:** User reports a local `cycletravels` repo, but it was not accessible in the connected GitHub results during spec creation. Cursor **must inspect** the actual local repo when present for auth, Flutter UI patterns, network configuration, and API reuse; do not claim specific code exists there without inspection.

**Reuse rules:** Favor copying/adapting small, reviewed utility code or architectural patterns into this new repo rather than introducing runtime cross-repo imports. Maintain new secrets, OAuth app/bundle IDs, Firebase app config, Railway project and Postgres DB. Identify licensing constraints if distributing copied code. Document exact source filenames/commit hashes for imported patterns in `docs/REUSE_AUDIT.md`.

---

## 2. Architecture and ownership

```text
Flutter client
  ├─ Authentication & Onboarding
  ├─ Goals / Dashboard / Trajectory
  ├─ Knowledge Explorer (hierarchical tree + edges)
  ├─ Learning Session (content + answer interactions)
  ├─ Daily Reviews
  └─ Mastery & Graph Change History
            │ authenticated REST + job polling
FastAPI modular monolith
  ├─ accounts                [existing auth patterns]
  ├─ knowledge_graph         [concepts, relations, releases, diffs]
  ├─ graph_evolution         [change proposals, validation, publication]
  ├─ goals_trajectories      [goals, diagnostics, planning]
  ├─ learning_content        [LLM activity generation, source grounding]
  ├─ learning_sessions       [attempts, assessments, feedback]
  ├─ retention              [review item/card state + FSRS scheduling]
  ├─ mastery                 [evidence projection, skill state, migration]
  ├─ platform               [LLM client, auth, jobs, audit, rate limits]
  └─ background_worker       [generation, validation, freshness, migrations]
            │
PostgreSQL (versioned domain state + jobs + audit)   Gemini API / vetted sources
```

**Dependency direction:** HTTP routers → application/use cases → domain logic → persistence/provider ports. Source-fetching/LLM clients are infrastructure adapters. Keep pure mastery, planner, and migration logic testable without an LLM or database. Database transactions wrap graph publication and state migrations, not external LLM calls.

**No “five LLM models.”** Five app components are software domains: (1) Versioned Graph, (2) Trajectories, (3) Learn/Generate, (4) Retain, (5) Mastery Intelligence. LLM use cases are functions within them, not separate always-running autonomous agents.

---

## 3. Canonical graph model and versioning

### 3.1 Terminology

- `Concept`: stable identity representing one semantically coherent capability or fact family, with an opaque UUID, not a mutable title or path. A learner may have multiple mastery dimensions/objectives for a concept.
- `ConceptRevision`: immutable definition, metadata, claim provenance, and semantic revision classification. Atomic learning objectives are first-class stable identities with immutable objective revisions linked to concept revisions.
- `ConceptEdge`: identity of a relationship; revisioned endpoints/type when changed. Typical edge types: `contains` (hierarchy), `prerequisite`, `related`, `supersedes`. Use `contains` as a DAG (no cycles), and choose one `primary_parent` path for default UI breadcrumb if multiple parents exist.
- `Graph`: one domain/workspace namespace, not the entirety of human knowledge.
- `GraphRelease`: immutable publication snapshot: selected concept revision IDs and edge revision IDs, source revision IDs, plus a content checksum; a workspace selects an active release.
- `GraphOverlay`: personal/provisional changes layered over a known base release; can be published to a user's private release immediately, but never silently promoted to the shared graph.
- `GraphChangeProposal`: a typed set of changes with before/after, rationale, citations, validation outcomes, risk class and explicit migration rules.
- `LearningObjective`: explicit, assessable capability with stable identity when possible (e.g. “calculate entropy from class frequencies”). Mastery evidence is tagged to objective IDs **and the revisions/rubrics used**.

**Source of truth:** The published release is a snapshot manifest of immutable revision IDs. Never overwrite published revisions. Store immutable membership rows or a checksum-verified manifest; for MVP favor normalized membership tables. A rollback creates a **new release** pointing to older revisions, not deletion of intervening history.

### 3.2 Schema (minimum entities)

Use SQL migrations with real foreign keys, uniques, `created_at`, provenance and tenant/owner columns. Suggested names:

| Entity | Important columns |
| --- | --- |
| `users` | `id`, `firebase_uid UNIQUE`, profile/preferences/timezone |
| `graphs` | `id`, `slug`, `title`, `owner_user_id NULL`, `visibility`, `active_release_id`, `created_at` |
| `concepts` | `id UUID`, `canonical_key NULL`, `origin_graph_id`, `scope`, `created_at` |
| `concept_revisions` | `id UUID`, `concept_id`, `revision_no`, `title`, `summary`, `knowledge_type`, `semantic_fingerprint`, `change_kind`, `source_status`, `created_at`, `creator` |
| `learning_objectives` | `id UUID`, `origin_concept_id`, `created_at`, `status` (stable objective identity) |
| `objective_revisions` | `id UUID`, `objective_id`, `concept_revision_id`, `revision_no`, `statement`, `success_criteria JSONB`, `cognitive_dimension`, `semantic_fingerprint`, `created_at` |
| `edges` | `id UUID`, `graph_id`, `created_at` |
| `edge_revisions` | `id UUID`, `edge_id`, `revision_no`, `from_concept_id`, `to_concept_id`, `type`, `is_primary_parent`, `created_at` |
| `graph_releases` | `id UUID`, `graph_id`, `version INTEGER`, `parent_release_id`, `overlay_id NULL`, `checksum`, `status`, `published_at`, `published_by`, `change_proposal_id` |
| `graph_overlays` | `id UUID`, `base_graph_id`, `owner_user_id`, `base_release_id`, `active_private_release_id`, `status`, `created_at` |
| `release_concepts` | `release_id`, `concept_id`, `concept_revision_id`, composite PK |
| `release_edges` | `release_id`, `edge_id`, `edge_revision_id`, composite PK |
| `graph_change_proposals` | `id`, `graph_id`, `base_release_id`, `actor_type`, `actor_user_id`, `trigger_type`, `operations JSONB`, `diff JSONB`, `validation JSONB`, `status`, `impact_summary`, `idempotency_key` |
| `concept_mappings` | `proposal_id`, `source_concept_id`, `target_concept_id`, `relation` (`equivalent`, `narrower`, `broader`, `overlap`, `replacement`, `removed`), `objective_mapping JSONB`, `confidence`, `validated_by` |
| `source_documents` | `id`, `source_url`, `title`, `publisher`, `retrieved_at`, `published_at`, `content_hash`, `trust_tier`, `license` |
| `source_claims` | `source_id`, `concept_revision_id`, `claim_key`, `support_status` |
| `learning_goals` | `id`, `user_id`, `title`, `target_outcomes JSONB`, `time_budget_minutes_week`, `target_depth`, `status`, `priority` |
| `goal_graphs` | `goal_id`, `graph_id`, `release_id`, `overlay_id NULL` (active release pointer for this goal) |
| `trajectories` | `id`, `goal_id`, `version`, `planner_version`, `generated_at`, `reason` |
| `trajectory_releases` | `trajectory_id`, `graph_id`, `release_id` (immutable pinned release set) |
| `trajectory_steps` | `id`, `trajectory_id`, `concept_id`, `objective_id`, `step_type`, `rank`, `status`, `rationale`, `estimated_minutes` |
| `learning_activities` | `id`, `concept_revision_id`, `objective_ids JSONB`, `kind`, `body JSONB`, `rubric JSONB`, `content_hash`, `prompt_version`, `model`, `review_status`, `created_at` |
| `learning_sessions` | `id`, `user_id`, `goal_id`, `trajectory_id`, `started_at`, `ended_at`, `status` |
| `assessment_attempts` | `id`, `user_id`, `session_id`, `activity_id`, `concept_revision_id`, `response JSONB`, `score`, `rubric_results JSONB`, `confidence`, `grading_method`, `grader_version`, `created_at` |
| `mastery_evidence` | `id`, `user_id`, `attempt_id`, `objective_id`, `objective_revision_id`, `concept_revision_id`, `dimension`, `likelihood_weight`, `observed_score`, `created_at`, `migration_origin_id NULL` |
| `learner_objective_states` | `user_id`, `objective_id`, `concept_id`, `active_revision_id`, `mastery_estimate`, `confidence`, `last_assessed_at`, `status`, `projection_version` |
| `review_items` | `id`, `user_id`, `concept_id`, `objective_id`, `objective_revision_id`, `activity_template_id`, `scheduler_version`, `fsrs_state JSONB`, `due_at`, `status` |
| `review_events` | `id`, `review_item_id`, `attempt_id`, `rating`, `reviewed_at`, `scheduler_version`, `before_state JSONB`, `after_state JSONB` |
| `migration_runs` | `id`, `user_id`, `from_release_id`, `to_release_id`, `proposal_id`, `status`, `created_at`, `completed_at`, `summary JSONB` |
| `migration_items` | `migration_run_id`, `source_objective_id`, `target_objective_id`, `policy`, `transferred_evidence_ids JSONB`, `result`, `reason`, `needs_reassessment` |
| `generation_jobs` | `id`, `user_id`, `type`, `state`, `payload JSONB`, `result JSONB`, `attempts`, `lease_until`, `idempotency_key`, `error_code`, timestamps |
| `llm_usage` | `user_id`, `job_id`, `task`, `provider`, `model`, `input_tokens`, `output_tokens`, `estimated_cost_usd`, `created_at` |
| `audit_events` | `id`, `actor`, `action`, `entity_type`, `entity_id`, `before JSONB`, `after JSONB`, timestamp |

**DB rules:**

- Unique `(concept_id, revision_no)`, `(objective_id, revision_no)`, `(graph_id, version, overlay_id)` with appropriate NULL-aware uniqueness, `(release_id, concept_id)`, `(user_id, objective_id)`, and stable idempotency keys scoped to actor/action.
- Check foreign keys to exact concept, objective, and rubric revision rows. Objective identity is relational; **do not use JSONB as the only storage for objective IDs**. No hard deletes of referenced published entities or assessment evidence. Use tombstones/statuses.
- Index `edges(from,to,type)`, `release_concepts(release_id, concept_id)`, `review_items(user_id, status, due_at)`, `learning_goals(user_id,status)`, `migration_runs(user_id,status)`.
- Prefer transactionally consistent read models/materialized caches for hierarchy and planners. Start with adjacency lists and recursive CTEs, not a custom graph server.
- All user rows must be owner-filtered in repository queries; test cross-user access. Never trust a `user_id` sent by clients.

### 3.3 Graph invariants and publishing

- `contains` hierarchy has **no cycles**. `prerequisite` graph has **no cycles** for hard prerequisites. `related` may cycle. Ensure every included edge references included concepts and valid revisions. Validate limits on depth, node count, fanout, duplicate labels and prerequisite coherence.
- Publication is serialized **per graph**: lock a per-graph release pointer row or graph row with `SELECT FOR UPDATE`; require matching `base_release_id` (otherwise `409 GRAPH_STALE` and rebase); insert immutable revisions + membership snapshot + audit; atomically advance the active release pointer.
- New/revised concepts enter `proposed` → `validated` → `published`; a personal overlay may activate `provisional` changes for that user immediately. Clearly label unverified content and limit unsupported factual claims.
- **Never call an LLM within a publication database transaction**. All generation/validation occurs in jobs before commit.
- Graph releases are **per graph**, not a single global version. A trajectory pins the exact release(s) it used using `trajectory_releases` (including for single-graph goals). A private overlay release is distinct from the shared release; a goal points to its own effective release.
- Concept IDs survive title changes and moves. **Semantic changes** create revision changes; true splits/merges create new concept IDs with explicit mappings, not silent identity repurposing.

---

## 4. The five core components

### Component A — Versioned Knowledge Graph

**Input:** goal text, source information, graph navigation, expansion request, maintenance triggers.  
**Output:** immutable validated nodes/edges/releases, readable hierarchy, change diff, migration mappings.

**Creation/expansion pipeline:**

1. Normalize topic and search existing graph by aliases, keywords, optionally embeddings later.
2. Reuse matching stable concepts instead of duplicating. Fetch the relevant existing neighborhood + parent/prerequisite context.
3. Generate a **bounded** branch proposal using structured JSON: candidate nodes, atomic objectives, prerequisite suggestions, parent relationships, source queries, uncertainties, suggested mappings to existing nodes.
4. Retrieve authoritative sources where possible; check links, freshness, and evidence for claims. Validate schema, dedup candidates, no cycles, bounded depth/fanout, well-formed objective IDs and stable references.
5. Store proposal + diff and source provenance. Permit a user to accept into their private overlay. Shared publishing is gated by stronger validation; human approval for high-risk/contested changes.
6. Create new graph release, prepare migration, activate eligible learner releases, and replan affected goals.

**Freshness policy:** assign `knowledge_type` (`timeless_foundation`, `evolving_research`, `software_versioned`, `time_sensitive`) and compute review priority from last verified date, source change signals, user reports and impact. A scheduled worker reviews **candidates**, not every graph node daily. Update *content artifacts* without changing graph semantics when only examples/tooling change.

**Endpoints:** `POST /graphs`, `GET /graphs/{id}/tree?release_id=`, `GET /graphs/{id}/concepts/{concept_id}`, `POST /graphs/{id}/expansions`, `GET /graph-jobs/{id}`, `GET /graphs/{id}/proposals/{id}`, `POST /graphs/{id}/proposals/{id}/accept-private`, `POST /graphs/{id}/proposals/{id}/publish` (admin/authorized), `GET /graphs/{id}/releases`, `GET /graphs/{id}/diff?from=&to=`, `POST /graphs/{id}/freshness-checks` (admin/authorized).

### Component B — Personalized Trajectories

**Input:** goal, desired outcomes, diagnostic evidence, release snapshot, time budget, prerequisite graph, retention queue.  
**Output:** ordered recommended activities/steps and an explanation of *why next*.

- Goal may include several knowledge domains; goals and interests change without deleting existing mastery.
- Diagnostic: self-reported background is low-confidence prior, followed by a short adaptive assessment over representative prerequisites. Unknown is **not** equivalent to failed.
- Plan algorithm (deterministic MVP): construct goal-relevant subgraph, compute prerequisite readiness, exclude clearly mastered objectives except due review, estimate learning utility per time, choose frontier items. Reserve separate review capacity each session. Sort with deterministic tie-breaking.
- Sketch score: `priority = goal_relevance × readiness × expected_gain × uncertainty_bonus / estimated_minutes`; apply hard gates for unmet prerequisites, availability and user preferences. Use configurable weights, log planner version and recommendations.
- Replan on goal editing, diagnostic completion, assessment, relevant due-review state transition or graph migration. Avoid persisting meaningless new versions for every UI read: update only when selected steps change.
- Existing plans should not silently mutate during an ongoing learning session. A session pins its trajectory/release; update on completion.

**Endpoints:** `POST /goals`, `PATCH /goals/{id}`, `GET /goals`, `POST /goals/{id}/diagnostic`, `GET /goals/{id}/trajectory`, `POST /goals/{id}/trajectory/replan`, `GET /goals/{id}/recommendation`.

### Component C — Learning Content / AI Tutor

**Input:** concept revision + atomic objective, learner state, previous attempts, selected activity type, verified sources.  
**Output:** structured, cached, version-pinned explanation/exercise/rubric and feedback.

Activity types in MVP:

- `explain`: concise explanation + analogy + counterexample + worked example (consumption alone earns no mastery).
- `retrieval_short_answer`: closed-book question and reference answer/rubric.
- `multiple_choice`: calibrated distractors, one best answer, exact grader (supplement, not sole assessment).
- `apply`: scenario or calculation requiring transfer; objective rubric.
- `teach_back`: learner explains a concept in their own words; LLM gives rubric-grounded structured feedback.

Generation uses **strict Pydantic-validated JSON** with an explicit `schema_version`, `concept_revision_id`, `objective_ids` and `objective_revision_ids`, `activity_type`, `content`, `answer`, `rubric`, `difficulty`, `sources`, `prompt_version`, `model`, and safety/grounding flags. Never send a raw unverified LLM blob directly to the UI. Cache by content key: concept revision + objective + task type + language + difficulty + prompt version (+ source snapshot). Regenerate on material revisions or repeated activity exposure.

**Answer assessment:** deterministic for MCQ, numeric/tolerance, exact-set tasks; rubric-based model evaluation for free text. Return per-objective score (0–1), error type, diagnostic feedback, confidence, grader model/prompt version, and supporting rationale (not hidden chain of thought). Avoid using the same vague LLM “confidence” as a calibrated probability. Mark low-confidence grading as uncertain and offer alternate assessment. Never award mastery solely from an AI explanation.

**Endpoints:** `POST /learning-sessions`, `GET /learning-sessions/{id}/next`, `POST /learning-sessions/{id}/attempts` (`Idempotency-Key`), `POST /learning-sessions/{id}/complete`, `POST /activities/generate` (returns job), `GET /activities/{id}`.

### Component D — Retention / Spaced Repetition

**Input:** objective-aligned retrieval item + attempt quality + previous review history.  
**Output:** due dates and choice of review task.

- Use an **established FSRS implementation** (pin its version; verify licensing and parameter definitions). Do not hand-wave “use Fibonacci” or repurpose confidence as a due date.
- FSRS schedules **review items**, not entire broad concepts. Link each review item to stable objective/skill and activity template. Preserve review event history, scheduler version and state transitions.
- Due reviews are mixed with new learning but managed distinctly: users see `Due`, `Learning`, `Overdue`; notifications optional. Retrieval is active (answer before reveal), with varied response modes.
- Grade mapping (e.g. Again/Hard/Good/Easy) must be explicit and calibrated from attempts where possible. Learner can correct rating; log overrides.
- On content-only revisions, keep item schedule; on materially changed objective/rubric, keep old history immutable but create/re-evaluate affected review item(s). A split never blindly duplicates an old retention state into all children.
- Use timezone-aware UTC timestamps; compute local-day summaries in user timezone. Completion and event insertion are idempotent.

**Endpoints:** `GET /reviews/due?limit=`, `POST /reviews/{review_item_id}/submit`, `GET /reviews/stats`.

### Component E — Mastery Intelligence

**Input:** immutable attempt-level evidence, objective/rubric metadata, graph version mappings, review performance.  
**Output:** per-objective mastery estimate + uncertainty, concept roll-ups, gaps, progress and replan triggers.

**MVP estimation:** configurable, explainable evidence-weighted/Bayesian approximation per objective, separate by dimension: `recall`, `understanding`, `application`. Use quality, recency, task difficulty, independence and grader reliability. Unknown begins with low certainty. Reading content or a self-rating should not produce a high mastery estimate. Maintain `mastery_estimate` **and** `confidence/evidence_count`, and allow reassessment.

- Group concept mastery as a clearly described roll-up of its objectives; avoid presenting `87%` as objective psychological truth.
- Keep **retention state separate from competence**: being overdue does not erase demonstrated historical skill; recent retrieval failures can reduce the current mastery estimate.
- Trigger planner updates only if evidence crosses configured thresholds or makes a different step optimal, to avoid noisy plan churn.
- Mastery snapshots are projections of immutable evidence, not the sole source of truth. They can be recalculated after migrations/algorithm updates.
- `mastery_model_version` recorded with projections; implement an offline recalculation command for testing, not a production-mutating job by default.

**Endpoints:** `GET /mastery/overview?goal_id=`, `GET /mastery/concepts/{concept_id}`, `GET /mastery/evidence?concept_id=`, `GET /mastery/gaps?goal_id=`.

---

## 5. Mandatory graph-change and mastery-migration protocol

**Invariant:** All learner evidence is immutable and remains linked to the exact historical concept revision, objective and assessment rubric. A migration never rewrites old attempts. It produces new mapping/projection state with traceable provenance.

### 5.1 Change classification and default migration policy

| Graph change | Graph action | Mastery action | Retention action |
| --- | --- | --- | --- |
| Rename / typo / metadata | new revision, same concept/objectives | preserve evidence and state 1:1 | preserve due state |
| Move node / reparent | edge revision | preserve 1:1 | preserve |
| Add unrelated sibling / branch | added concept(s) | existing states unchanged; new objectives unknown | new items only after learning |
| Add prerequisite | edge revision | preserve existing demonstrated capability; flag prerequisite gap | preserve, recommend bridge work |
| Rewrite lesson or source links, objectives unchanged | content/artifact revision | preserve | preserve, invalidate affected content cache |
| Correct materially wrong definition / changed objectives | semantic revision | migrate only aligned evidence; affected objective `needs_reassessment` | reschedule affected items |
| Split 1 concept into N | new concept IDs + objective mapping | transfer **only objective-specific supported evidence** to matching descendants; leave uncovered objectives unknown | remap equivalent items only, do not clone one review schedule N times |
| Merge N concepts into 1 | new concept ID + mapping | union nonduplicate evidence by target objective, then recompute; do not add or average mastery percentages | consolidate duplicate aligned review items, retain history |
| Deprecate / replace | tombstone + supersedes link | archive legacy state, transfer only proven equivalent objective evidence | retire or remap items according to equivalence |
| Conflicting/corrected facts | new semantic revision + source record | preserve historical evidence, reduce or invalidate applicability to new claim; show updated gap | prioritize correction-focused review |

**Important:** A concept-level mapping `equivalent/narrower/broader/overlap` is a *proposal*, not sufficient for automatic mastery transfer. Objective-to-objective mappings and compatible assessment rubrics determine evidence portability. “Unmapped” and “unknown” are legitimate outcomes. Never copy a parent’s 90% mastery to every new child.

### 5.2 Migration algorithm

For any accepted graph release transition (personal or shared):

1. **Prepare immutable diff**: added/modified/deprecated concepts, edges, objectives, prerequisites, content dependencies, source changes.
2. **Generate migration mappings**: identity/equivalence mapping for safe unchanged objectives; explicitly proposed mappings for split, merge, semantic change. Validate mappings against revision IDs and objective scopes. High-impact uncertain mappings require review.
3. **Preview impact** per learner: number preserved, needs reassessment, new, archived, affected due reviews, trajectory changes. Persist migration plan and mapping provenance.
4. **Publish release** transactionally, with its mapping manifest. New users can use it immediately; existing users stay pinned to their current release until individual migration completes.
5. **Run learner migration idempotently** in a worker, keyed `(user_id, from_release_id, to_release_id)`; lock relevant learner/goal rows; read original immutable evidence; project compatible evidence into new objective states with explicit `migration_origin_id` references; recompute mastery/uncertainty; remap or create review items; record results.
6. **Atomically activate** the target release for that learner's affected goal(s) only after a successful migration. Replan trajectories in the same logical workflow; live sessions remain pinned to old revisions until finished.
7. **Notify** learner of meaningful changes; provide `View diff`, `What changed for me`, and `Reassess gaps`. On failure keep the previous active release, retry safely, and never corrupt source evidence.

**Scalability:** shared release publishing must not block on migrations for all learners. Use per-learner lazy upgrades and background batch jobs. A migration may be scheduled when a learner next opens a relevant goal.

### 5.3 Concrete examples that MUST pass tests

- **User-driven branch expansion:** A learner expands ML → Decision Trees → Splitting Criteria with new `Entropy` and `Information Gain`. Existing `Decision Trees` objectives and mastery remain unchanged, new ones are `unknown`, trajectory adds prerequisites appropriately, and no duplicate review cards appear.
- **Node reparenting:** `Entropy` moves under `Information Theory`. User assessment evidence, review schedule and learned status are unchanged.
- **Split:** A previously broad `Neural Networks` node splits into `Feedforward Networks`, `CNNs`, `Transformers`. Only explicitly tagged objectives (e.g. feedforward fundamentals) transfer; unfamiliar subtopics are unknown. No 100%-to-all-children propagation.
- **Merge:** Two redundant nodes `Gradient Descent Basics` and `Optimization with Gradient Descent` merge. Equivalent objectives' evidence is deduplicated by attempt/evidence ID and recomputed; no double-counting.
- **Revised fact:** Existing source-backed claim becomes outdated. Earlier attempt remains auditable; current revised objective is marked `needs_reassessment` if old evidence no longer demonstrates the revised claim.
- **Migration retry:** Worker crashes after writing intermediate rows. Retrying with the same idempotency key creates no duplicate projections, review items or releases.
- **Concurrent publish:** Two proposals based on the same release cannot both advance the active pointer; one gets a stale-base result and must rebase.

**Endpoints:** `GET /graphs/{id}/migration-preview?proposal_id=&goal_id=`, `GET /migrations/{id}`, `POST /goals/{id}/upgrade-graph`, `GET /goals/{id}/graph-changes`.

---

## 6. API contracts and job semantics

Use `/api/v1`, Pydantic DTOs and OpenAPI; TypeScript is **not** required for Flutter. Build generated JSON fixtures and contract tests for client/server. All writes require auth/authorization, validated inputs and idempotency for retries. Use consistent error format: `{ "code": "...", "message": "...", "details": {} }`.

### Essential request/response examples

#### Create a goal

`POST /api/v1/goals`

```json
{
  "topic": "Machine learning",
  "purpose": "Build professional ML systems",
  "target_depth": "professional",
  "minutes_per_week": 180,
  "language": "en"
}
```

`202 Accepted` (if graph/diagnostic generation required):

```json
{
  "goal_id": "<uuid>",
  "status": "preparing",
  "job_id": "<uuid>",
  "graph_id": "<uuid>",
  "graph_release_id": null
}
```

#### Propose graph expansion

`POST /api/v1/graphs/{graph_id}/expansions`

```json
{
  "base_release_id": "<uuid>",
  "parent_concept_id": "<uuid>",
  "instruction": "Expand information-theoretic splitting criteria",
  "max_depth": 2,
  "max_new_concepts": 12,
  "visibility": "private"
}
```

`202 Accepted`: `{ "job_id": "<uuid>", "proposal_id": "<uuid>", "status": "generating" }`.

#### Graph diff / migration preview

`GET /api/v1/graphs/{graph_id}/migration-preview?proposal_id=<uuid>&goal_id=<uuid>`

```json
{
  "proposal_id": "<uuid>",
  "from_release_id": "<uuid>",
  "candidate_to_release_version": 4,
  "impact": {
    "preserved_objectives": 18,
    "new_objectives": 3,
    "reassessment_objectives": 1,
    "retired_review_items": 0
  },
  "mappings": [
    { "source_objective_id": "<uuid>", "target_objective_id": "<uuid>", "policy": "preserve", "confidence": 1.0 }
  ],
  "warnings": []
}
```

#### Submit an assessment

`POST /api/v1/learning-sessions/{session_id}/attempts` with `Idempotency-Key` header.

```json
{
  "activity_id": "<uuid>",
  "answer": { "text": "Entropy measures uncertainty..." },
  "client_submitted_at": "2026-11-07T14:00:00Z"
}
```

`200/201`: `{ "attempt_id": "<uuid>", "grading_status": "graded", "feedback": { "score": 0.8, "criterion_results": [], "next_hint": "..." }, "mastery_update": { "objectives_changed": 1 }, "trajectory_version": 7 }`. For async free-text grading, return `202` with a grading job ID; polling must be supported.

### Job lifecycle

`queued → running → succeeded | failed | canceled`, with `lease_until`, retry count, terminal error code and monotonic `updated_at`. Workers use `SELECT ... FOR UPDATE SKIP LOCKED`, short DB transactions, external LLM call outside transactions, and final compare-and-swap writes. Exponential backoff and poison-job quarantine. `GET /api/v1/jobs/{id}` returns status/progress/result/error; user can poll it. Unique idempotency keys must avoid duplicate paid LLM calls when possible; cached generation results are reused.

### Error handling

- `409 GRAPH_STALE`: version or base release mismatch; return current release and rebase hint.
- `422 INVALID_GRAPH`: cycle, dangling edge, invalid objective/rubric or schema violation.
- `403 FORBIDDEN`: wrong owner or non-admin shared publication.
- `429 RATE_LIMITED`: exceeded generation or request quota.
- `503 GENERATION_UNAVAILABLE`: model failed/timeouts; job retryable, existing content still usable.
- `409 MIGRATION_PENDING`: learner/goal activation not complete; allow old-version read sessions.

---

## 7. UI / navigation specification

**Design direction:** mature, minimal, information-dense but calm, polished hierarchy navigation. Avoid gamification clutter and chat-only learning. Mobile-first but support a split-pane tablet/web layout.

**Primary navigation (5 tabs):**

1. **Home** — selected goal, today's planned learning time, next recommended concept, due reviews, recent progress, switch goal.
2. **Map** — collapsible hierarchical topic tree (primary interface); mastery color/status; prerequisite chips/edges; concept detail sheet; `Expand branch` action; search and filters; revision notice. Handle large graphs through lazy loading/virtualization.
3. **Learn** — active session; explanation, worked example, prompt, answer input, grading feedback, next action; route guided by plan rather than free-form AI chat alone.
4. **Review** — due items, short-answer retrieval before reveal, correctness/quality feedback, skip/defer, daily summary.
5. **Mastery** — per-goal progress, confidence, dimensions, weakest prerequisites, review outlook, timeline, graph-update history.

**Onboarding:** auth → goal prompt → purpose/depth/time → `Building your map` job progress → interactive diagnostic → overview of generated first trajectory → start learning.

**Graph update UX:** in-map small change marker; release diff sheet shows added/moved/revised/deprecated nodes and source dates; personal impact panel: `18 skills kept`, `3 new`, `1 needs recheck` (example only). User can keep current release temporarily or adopt new one; serious factual corrections can block new learning on invalidated material while leaving history visible.

**Empty/loading/errors:** explicit async generation progress, resumable jobs, retryable failures, no placeholder content masquerading as generated lessons. Accessibility: semantics, screen reader labels, text scaling, color-independent mastery labels.

---

## 8. LLM prompts, source validation, cost, safety

Create typed tasks behind one `LLMProvider` protocol:

- `propose_graph_branch(context, parent, goals, sources)` → `GraphChangeProposalDTO`
- `propose_graph_update(old_revision, source_diff)` → `GraphChangeProposalDTO`
- `generate_activity(objectives, learner_context, source_context, type)` → `LearningActivityDTO`
- `grade_open_answer(activity, rubric, answer)` → `GradingDTO`
- `propose_objective_mapping(before, after, evidence_metadata)` → `ObjectiveMappingDTO`

Each task has prompt template version, JSON schema, max input/output tokens, timeout, retry policy, model choice, cost logging and rate limit. Use Gemini from reference repos first; choose models via environment variables. **Do not expose AI model selection in normal UI**. Use deterministic controls for graph cycles, ownership, objective IDs, invalidation and scheduler changes. Never trust LLM-proposed IDs as authoritative: server assigns IDs/validates refs.

**Source requirements:** persist URLs/title/retrieval time/hash/trust class for AI-generated factual lessons and graph changes. Distinguish `verified`, `source_pending`, `user_custom`, and `disputed`. Curated authoritative sources are preferred for core factual content. If retrieval fails, fail closed on publishing high-impact updates; ordinary learning content can show an explicit uncertainty label and request validation. Don't claim that a plausible LLM answer is independently verified.

**Cost controls:** cache graph expansions/content by stable hashes; cap expansion breadth; generate only next few activities; review prompts can reuse templates; deterministic graders when possible; daily per-user generation quota; log model/tokens/estimated cost; bounded queue concurrency. Protect all endpoints from prompt injection and untrusted retrieved content; never allow LLM-produced operations to bypass authorization or publish directly.

---

## 9. Repository layout, configuration and deployment

Recommended new monorepo:

```text
adaptive-mastery/
  AGENTS.md
  README.md
  docs/
    SPEC.md                  # copy of this specification
    REUSE_AUDIT.md
    ARCHITECTURE.md
    ADR/                     # significant design choices
  backend/
    app/
      main.py
      core/                   # settings, db, auth, logging
      features/
        accounts/
        knowledge_graph/
        graph_evolution/
        goals_trajectories/
        learning_content/
        learning_sessions/
        retention/
        mastery/
      infra/                  # LLM adapters, job runner, source retriever
      workers/
    alembic/
    tests/
    pyproject.toml
    Dockerfile
  flutter/
    lib/
      core/                   # app router, API client, auth, theme
      features/
        onboarding/
        goals/
        knowledge_graph/
        trajectory/
        learning/
        review/
        mastery/
    test/
    integration_test/
    pubspec.yaml
  deploy/
    railway-api.toml
    railway-worker.toml
  .env.example
  Makefile
```

**Environment variables (document, never commit secret values):**

```dotenv
ENVIRONMENT=development
DATABASE_URL=postgresql://...
SECRET_KEY=...
FIREBASE_SERVICE_ACCOUNT_JSON=...
GOOGLE_GEMINI_API_KEY=...
GEMINI_MODEL=...
GEMINI_TEMPERATURE=0.0
CORS_ORIGINS=http://localhost:8080
SENTRY_DSN=
LLM_DAILY_TOKENS_USER_LIMIT=...
GRAPH_EXPANSION_MAX_NODES=12
JOB_WORKER_CONCURRENCY=2
GRAPH_FRESHNESS_CHECK_ENABLED=false
```

**Railway:** Separate API service, worker service and managed Postgres; use the same code/image with different startup commands. API health endpoint `/health` and worker health/heartbeat. Alembic migration runs exactly once per deployment via explicit deployment step, not concurrently in each replica. Environment-specific config, staging database, connection pooling, TLS where required. Job worker and scheduled freshness audit must be explicitly enabled; avoid unbounded web/API costs.

---

## 10. Acceptance criteria and test matrix

### Functional acceptance scenarios

- [ ] Sign in via the selected existing Firebase pattern; logout and token refresh work.
- [ ] User enters a new topic and receives a **real** stored hierarchy, not placeholder nodes, with a published/private release ID.
- [ ] Hierarchy tree expands/collapses and displays typed prerequisites, no cyclic hard prerequisite relations.
- [ ] Goal diagnostic populates tentative objective states with uncertainty.
- [ ] Planner generates an explainable trajectory of ready-to-learn concepts.
- [ ] Learner completes one actual lesson and one objective-aligned assessed question.
- [ ] Assessment persists immutable evidence and updates objective mastery correctly.
- [ ] Daily review item is scheduled with the configured FSRS implementation and can be completed again later.
- [ ] Replanning considers new knowledge and due reviews without destroying existing plans/sessions.
- [ ] Goal switch preserves prior evidence and generates a new relevant path.
- [ ] User expands a branch: new release/overlay, diff and migration preview exist, new objectives unknown, old states preserved.
- [ ] Knowledge-driven maintenance produces source-backed change proposal and controlled publish (not direct LLM mutation).
- [ ] Split/merge/reparent/prerequisite/correction/deprecation migrate evidence according to Section 5.
- [ ] Old activities/attempts display correctly against historical revisions.
- [ ] Failed/stale/concurrent publishing or migration can be retried without duplicates/data loss.
- [ ] No user can read or mutate another user's goals, attempts, private overlays or mastery.

### Required automated tests

**Pure domain unit tests:** cycle detection, duplicate detection, graph diff, objective mappings, deterministic planner ranking, mastery projection, score aggregation, FSRS state transitions, timezone handling.

**Migration/property tests:** evidence conservation and deduplication, split/merge no fabricated mastery, idempotency across retries, stale-publish conflict, retained historical access, review-state invariants.

**API integration tests:** auth isolation, graph creation and release reads, proposal/publish, asynchronous job polling, attempt submission idempotency, goal switch, migration/activation with transactional rollback.

**Flutter tests:** onboarding, lazy tree, concept detail, session answer feedback, review grading, graph-update diff, session-expired behavior, loading/error states.

**End-to-end demo seed:** a small deterministic topic (`Decision Trees`) with `Entropy`, `Information Gain`, a few objective-specific questions, one goal and a simulated graph split. Test the entire user journey without paid LLM calls by using fixture/fake provider.

**CI gates:** `pytest`, Alembic upgrade on empty DB, static type/lint checks, `flutter analyze`, `flutter test`, contract smoke tests. Include tests that fail if graph publish or mastery migration mutates historical assessment evidence.

---

## 11. Phased implementation plan (Cursor execution order)

### Phase 0 — Bootstrap and reuse

- Inspect `git/archipelago`, `git/mesozoica`, `git/cycletravels` or actual paths; read their `AGENTS.md` and relevant auth/LLM/client/database code.
- Create `docs/REUSE_AUDIT.md` with exact references and differences.
- Scaffold new Flutter + FastAPI monorepo, Railway config, DB connection, Alembic, auth, authenticated API client, jobs, test tooling.
- **Exit:** User signs in, calls a protected `/me`, sees a real dashboard; CI passes.

### Phase 1 — Core graph and releases

- Implement tables, graph queries, revision schemas, invariant checks, immutable release publish with per-graph locking, diff API, seed data.
- Implement hierarchical explorer and concept details.
- **Exit:** Can create/read/expand/collapse a versioned graph with immutable v1/v2, diff and rollback-as-new-release.

### Phase 2 — Goal + personalized planning

- Implement goal creation, diagnostic, learner states, initial deterministic planner and trajectory UX.
- **Exit:** Different prior knowledge/goals lead to measurably different next-step recommendations.

### Phase 3 — Learn + assess + retain

- Implement LLM adapter and structured activity generation, validated cached content, sessions, grading, mastery projection, FSRS, daily reviews.
- **Exit:** User completes a genuine learn → attempt → mastery → replan → later-review loop. No mocked learning state.

### Phase 4 — Graph evolution + mastery migration

- Implement user-driven expansion proposal and private overlay, source-backed maintenance proposal, diff, publish, mappings, preview, idempotent worker migration, learner release activation, change history UX.
- **Exit:** All split/merge/reparent/correction migration tests in Section 5 pass with history intact.

### Phase 5 — Reliability / production

- Implement worker leases/backoff, limits, audit/logging, Sentry, cached fallback content, source freshness audit, usability polish, security checks, staging deploy.
- **Exit:** Railway deployment works end-to-end, worker restart/retry is safe, core functionality remains usable under LLM outage.

**Ordering note:** Build a simple private branch-expansion path early in Phase 1 if needed for the demo, but do not call it complete until semantic migrations are implemented in Phase 4.

---

## 12. Implementation decisions that must not be skipped

1. **Stable graph identity is not a mutable string path.** Use UUID identity and immutable revisions.
2. **Version the graph, concept semantics, objectives, activity rubrics and scheduler/model algorithms**, not just the displayed tree.
3. **Personal/private graph overlays are separate from shared published catalog changes.** A user can experiment immediately without corrupting other users' knowledge maps.
4. **Pin sessions and evidence to revisions**; no historical rewriting.
5. **Plan mastery migrations before graph activation**; preserve state only where objective equivalence actually holds.
6. **Unknown ≠ unmastered ≠ forgotten.** Represent status and uncertainty explicitly.
7. **Retained knowledge and demonstrated competence are related, but not identical state.** Do not equate FSRS stability with mastery.
8. **LLM may propose; code validates and publishes.** Never let an LLM directly update database tables through freeform SQL.
9. **Avoid premature complexity:** one modular FastAPI service, one worker, Postgres graph, one LLM adapter, deterministic planner first.
10. **User benefit over architecture:** every phase must produce a runnable vertical slice, visible in Flutter, backed by real API/database operations.

## 13. Final Cursor delivery checklist

At the end, report:

- Working local startup commands and Railway deployment/setup steps.
- Reused code/pattern references and what was deliberately not copied.
- Database ERD and Alembic migration status.
- List of implemented endpoints and generated OpenAPI path.
- Demo walkthrough: goal → generated hierarchy → personalized path → learn → assess → review → replan → expand branch → migration preview/activate.
- Tests run and their actual results, with any unimplemented features clearly marked.
- Security/cost limitations, including which AI-generated source claims still require verification.

**Definition of done:** A new user can learn an unfamiliar topic end-to-end; a changing graph never silently erases, fabricates, or misattributes that user's mastery; and every meaningful learning decision can be traced to a graph release, objective, assessment evidence, model/scheduler version, and trajectory rule.
