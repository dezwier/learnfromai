# ADR 006 — Mastery projection

`mastery_model_version` is `weighted-mean-v1`.

For one objective and its evidence:

- Each row contributes `min(likelihood_weight, method cap) * score`.
- Caps: self-report and reading 0.15, multiple choice 0.55, model grades 0.85, exact and keyword 1.
- Estimate is the weighted mean. Confidence is `weight_sum / (weight_sum + 4)`.
- No evidence means status `unknown`.
- Only weak evidence, or confidence under 0.2, stays `learning` or `unknown`.
- `demonstrated` requires estimate at least 0.75, confidence at least 0.5, and no uncertain grade.
- A migration can force `needs_reassessment` or `archived` without deleting evidence.

Concept status is the most serious objective status, in this order: needs recheck, learning, unknown, archived, demonstrated. The screen shows the estimate and confidence. It does not present the number as a psychological score.
