# Reuse audit

Reference checkouts were read and left unchanged. Patterns were adapted into this repo. Nothing is imported across repositories at runtime.

| Source | Commit | What was adapted | Why |
| --- | --- | --- | --- |
| `git/archipelago` | `15af48563e82830e986df8a103974d6335ab6ce0` | Firebase ID-token verification, exchange for a PyJWT `access_token`, Flutter bearer client with GET retry and 401 handling, Gemini JSON mime type, fence stripping, usage metadata, Alembic `env.py` shape, pytest users minted with `create_access_token` | Same auth stack the spec requires, without a second password API |
| `git/mesozoica` | `49c3d82eba38feadab89943814d4d59c5c0c46c3` | Feature layout, `SELECT … FOR UPDATE` publish with a checksum, Flutter single-flight 401 refresh, model registry for Alembic, worker lease plus `SKIP LOCKED` | Release pointer and job claiming, changed from one global config row to one pointer per graph |
| `git/cycle_travels` | `44108a84c6e93a0521ca3b987c1c7003f34a3ce6` | Worker poll loop, `FOR UPDATE SKIP LOCKED` claim, pulsing full-size placeholder, separate API and worker processes | This repo has the clearest Postgres job loop and the placeholder rule. It has no Firebase auth and no LLM |

Deliberately not copied: Mesozoica's singleton release row, in-memory config cache, and YAML source; Archipelago media/R2 and topic business logic; CycleTravels email/password login, Strava, and Komoot. No production secrets or app ids were copied.

Token storage differs on purpose. The reference apps keep the API JWT in SharedPreferences. This app uses `flutter_secure_storage` because the spec asks for platform secure persistence.

The HTTP error body is `{code, message, details}`. Mesozoica's `{detail, type}` shape was not reused.
