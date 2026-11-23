"""Leitner bin moves and interval scheduling for pack reviews."""

from __future__ import annotations

from datetime import datetime, timedelta

from app.features.reviews.models import (
    GRADUATION_BIN,
    LEITNER_BIN_8_HOURS,
    LEITNER_INTERVALS_HOURS,
    UserPackReview,
)


def interval_hours_for_bin(bin_number: int) -> int:
    """Review interval hours by resulting bin (bin <= 0 treated as 1).

    Bins 1..7 use fixed hours. Bin 8 uses LEITNER_BIN_8_HOURS (6w); each higher
    bin adds the gap between bin 7 and bin 8 (+2w).
    """
    intervals = list(LEITNER_INTERVALS_HOURS)
    if bin_number <= 1:
        return intervals[0]
    if bin_number <= len(intervals):
        return intervals[bin_number - 1]
    step_hours = LEITNER_BIN_8_HOURS - intervals[-1]
    extra_bins = bin_number - len(intervals)
    return LEITNER_BIN_8_HOURS + (extra_bins - 1) * step_hours


def enroll_first_learn(row: UserPackReview, *, at: datetime) -> None:
    """Place a newly completed pack into bin 1 and schedule the first review."""
    row.leitner_bin = 1
    row.last_review_time = at
    row.next_review_at = at + timedelta(hours=interval_hours_for_bin(1))
    row.graduated_at = None


def apply_review_result(
    row: UserPackReview,
    *,
    correct: bool,
    at: datetime,
) -> bool:
    """Apply correct (+1) / incorrect (−2) when the card is due.

    Returns True when the row was updated.
    """
    if row.leitner_bin < 1:
        enroll_first_learn(row, at=at)
        return True

    current_next = row.next_review_at
    if current_next is not None and at < current_next:
        return False

    current_bin = row.leitner_bin
    if correct:
        new_bin = current_bin + 1
    else:
        new_bin = max(1, current_bin - 2)

    row.leitner_bin = new_bin
    row.last_review_time = at
    row.next_review_at = at + timedelta(hours=interval_hours_for_bin(new_bin))
    if new_bin >= GRADUATION_BIN and row.graduated_at is None:
        row.graduated_at = at
    return True
