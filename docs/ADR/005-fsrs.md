# ADR 005 — Leitner testing track (supersedes FSRS)

Status: **Accepted.** The earlier FSRS pin (`fsrs` 6.3.2 / `review_items`) is **superseded** and was never shipped.

## Decision

Retention for atomic learning packs uses the **Leitner system** (same rules as Talivo), not FSRS.

- Unit of review: one completed pack `(user, node_id, pack_index)` in `user_pack_reviews`.
- On atomic completion (`learn` + any check), enroll at **bin 1** with `next_review_at = now + 3h`.
- Correct → `bin + 1`. Incorrect → `max(1, bin − 2)`.
- Due when `next_review_at < now`. Not-due reviews do not move the bin.
- Graduation at **bin 8** (`graduated_at`); bins continue past 8 with longer intervals.
- Intervals (hours): 1→3, 2→12, 3→24, 4→48, 5→96, 6→168, 7→336, 8→672; bin `n>8` → `672 + (n−8)×336`.
- Each review quiz is a **random** pack check (`check1`/`check2`/`check3`), not FSRS ratings.

## APIs

- `GET /api/v1/me/reviews/distribution`
- `GET /api/v1/me/reviews/due`
- `POST /api/v1/me/reviews/submit`

Check answers still append to `user_topic_events`; submit also updates Leitner state.
