# ADR 005 — Leitner testing track (supersedes FSRS)

Status: **Accepted.** The earlier FSRS pin (`fsrs` 6.3.2 / `review_items`) is **superseded** and was never shipped.

## Decision

Retention for learning atoms uses the **Leitner system** (same rules as Talivo), not FSRS.

- Unit of review: one completed atom `(user, node_id, pack_index)` in `user_pack_reviews`.
- On atomic completion (`learn` + any check), enroll at **bin 1** with `next_review_at = now + 1d`.
- Correct → `bin + 1`. Incorrect → `max(1, bin − 2)`.
- Due when `next_review_at < now`. Not-due reviews do not move the bin.
- Graduation / mastered color at **bin 7** (`graduated_at`); bins continue past 7 with longer intervals.
- Groups: 1–2 learning, 3–4 familiar, 5–6 strong, 7+ mastered.
- Intervals (hours): 1→24, 2→48, 3→96, 4→168, 5→336, 6→504, 7→672, 8→1008; bin `n>8` → `1008 + (n−8)×336` (+2w each).
- Each review quiz is a **random** atom check (`check1`/`check2`/`check3`), not FSRS ratings.

## APIs

- `GET /api/v1/me/reviews/distribution`
- `GET /api/v1/me/reviews/due`
- `POST /api/v1/me/reviews/submit`

Check answers still append to `user_topic_events`; submit also updates Leitner state.
