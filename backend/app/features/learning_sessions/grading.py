from __future__ import annotations

from dataclasses import dataclass


@dataclass(frozen=True)
class GradeResult:
    score: float
    method: str
    confidence: float
    criterion_results: list[dict]
    next_hint: str
    uncertain: bool
    dimension: str


def grade_deterministic(kind: str, body: dict, rubric: dict, answer: dict) -> GradeResult | None:
    """Return None when a model rubric must grade the answer."""
    mode = rubric.get("mode")
    dimension = rubric.get("dimension") or _default_dimension(kind)
    if kind == "explain":
        return None
    if kind == "multiple_choice" or mode == "exact_choice":
        expected = (body.get("answer") or {}).get("choice")
        got = answer.get("choice")
        score = 1.0 if got is not None and got == expected else 0.0
        return GradeResult(
            score,
            "mcq",
            1.0,
            [{"id": "choice", "met": score == 1.0}],
            "" if score == 1.0 else "Check the definition against the choices again.",
            False,
            dimension,
        )
    if mode == "numeric":
        expected = float(body.get("answer", {}).get("value"))
        tolerance = float(rubric.get("tolerance", 0.01))
        try:
            got = float(answer.get("value"))
        except (TypeError, ValueError):
            got = None
        score = 1.0 if got is not None and abs(got - expected) <= tolerance else 0.0
        return GradeResult(score, "numeric", 1.0, [{"id": "value", "met": score == 1.0}], "", False, dimension)
    if mode == "keyword":
        text = str(answer.get("text") or "").lower()
        needles = [str(item).lower() for item in rubric.get("must_include", [])]
        if not needles:
            return GradeResult(0.0, "keyword", 1.0, [], "Name the idea in your own words.", False, dimension)
        results = [{"id": needle, "met": needle in text} for needle in needles]
        score = sum(1 for item in results if item["met"]) / len(results)
        missing = [item["id"] for item in results if not item["met"]]
        hint = "" if not missing else "Include: " + ", ".join(missing[:3])
        return GradeResult(score, "keyword", 1.0, results, hint, False, dimension)
    if mode == "model":
        return None
    return None


def _default_dimension(kind: str) -> str:
    if kind in {"retrieval_short_answer", "multiple_choice"}:
        return "recall"
    if kind == "teach_back":
        return "understanding"
    return "application"
