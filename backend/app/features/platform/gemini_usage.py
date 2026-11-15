"""Bill Gemini calls from response usageMetadata + published USD rates.

The Gemini API has no account spend/balance endpoint. The only live signal is
usageMetadata on each generateContent response. Thinking tokens
(thoughtsTokenCount) are billed as output.
"""

from __future__ import annotations

# Official Google AI Studio paid rates (USD per 1M tokens). Unknown models use
# a conservative high rate so a misconfigured GEMINI_MODEL cannot silently under-bill.
_RATES_USD_PER_M: dict[str, tuple[float, float]] = {
    "gemini-2.0-flash": (0.10, 0.40),
    "gemini-2.0-flash-001": (0.10, 0.40),
    "gemini-2.5-flash-lite": (0.10, 0.40),
    "gemini-2.5-flash": (0.30, 2.50),
    "gemini-3-flash-preview": (0.50, 3.00),
    "gemini-3.5-flash-lite": (0.30, 2.50),
    "gemini-flash-lite-latest": (0.10, 0.40),
    "gemini-flash-latest": (0.30, 2.50),
}
_DEFAULT_RATES = (1.00, 5.00)


def rates_for_model(model: str) -> tuple[float, float]:
    key = (model or "").strip().lower().removeprefix("models/")
    if key in _RATES_USD_PER_M:
        return _RATES_USD_PER_M[key]
    for prefix, rates in _RATES_USD_PER_M.items():
        if key.startswith(prefix):
            return rates
    return _DEFAULT_RATES


def usage_from_gemini_metadata(model: str, meta: dict | None) -> dict:
    """Turn Gemini usageMetadata into tokens + USD. Prefer API counts only."""
    meta = meta if isinstance(meta, dict) else {}
    prompt = int(meta.get("promptTokenCount") or 0)
    candidates = int(meta.get("candidatesTokenCount") or 0)
    thoughts = int(meta.get("thoughtsTokenCount") or 0)
    cached = int(meta.get("cachedContentTokenCount") or 0)
    # Cached tokens are billed cheaper; subtract from prompt when present.
    billable_input = max(0, prompt - cached) if cached else prompt
    # Thinking is billed as output (Google pricing page).
    billable_output = candidates + thoughts
    input_rate, output_rate = rates_for_model(model)
    # Cached input ~10% of input for flash-lite; use 0.1× input rate when cached.
    cached_cost = cached * (input_rate * 0.1) / 1_000_000 if cached else 0.0
    cost_usd = (
        billable_input * input_rate / 1_000_000
        + billable_output * output_rate / 1_000_000
        + cached_cost
    )
    return {
        "model": model,
        "input_tokens": prompt,
        "output_tokens": billable_output,
        "thoughts_tokens": thoughts,
        "cached_tokens": cached,
        "estimated_cost_usd": cost_usd,
        "source": "gemini_usage_metadata",
    }


def reserve_usd_for_call(model: str, max_output_tokens: int) -> float:
    """Worst-case USD for one call if the model fills maxOutputTokens (incl. thinking)."""
    _, output_rate = rates_for_model(model)
    # Small prompt pad so we do not approve a call that would tip over the cap.
    input_pad = 2_000
    input_rate, _ = rates_for_model(model)
    return (
        input_pad * input_rate / 1_000_000
        + max(0, int(max_output_tokens)) * output_rate / 1_000_000
    )
