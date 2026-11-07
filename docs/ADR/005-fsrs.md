# ADR 005 — FSRS pin

Review scheduling uses the `fsrs` package at version 6.3.2 (MIT, `open-spaced-repetition/py-fsrs`). `scheduler_version` on each review item and event is `fsrs-6.3.2`.

FSRS state is stored on `review_items`. `review_events` keep the before and after state. The scheduler does not decide mastery. An overdue item does not delete demonstrated evidence. A split moves one schedule onto the equivalent objective and does not copy it to every child.

Ratings map from the attempt score: below 0.4 again, below 0.7 hard, below 0.9 good, otherwise easy. The client may override the rating. Overrides are stored on the event.
