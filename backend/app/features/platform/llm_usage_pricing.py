"""Bill LLM calls from provider usage + published USD rates.

Unknown models use a conservative high rate so a misconfigured model env
cannot silently under-bill.
"""

from __future__ import annotations

# Official paid rates (USD per 1M tokens): (input, output).
_RATES_USD_PER_M: dict[str, tuple[float, float]] = {
    # Gemini (Google AI Studio). Output includes thinking when billed that way.
    "gemini-2.0-flash": (0.10, 0.40),
    "gemini-2.0-flash-001": (0.10, 0.40),
    "gemini-2.5-flash-lite": (0.10, 0.40),
    "gemini-2.5-flash": (0.30, 2.50),
    "gemini-3-flash-preview": (0.50, 3.00),
    "gemini-3.5-flash-lite": (0.30, 2.50),
    "gemini-flash-lite-latest": (0.30, 2.50),
    "gemini-flash-latest": (0.30, 2.50),
    # OpenAI
    "gpt-4o-mini": (0.15, 0.60),
    "gpt-4o-mini-2024-07-18": (0.15, 0.60),
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


def usage_from_tokens(
    model: str,
    *,
    input_tokens: int,
    output_tokens: int,
    thoughts_tokens: int = 0,
    cached_tokens: int = 0,
    source: str = "llm_usage",
) -> dict:
    """Turn token counts into the shared usage dict with estimated USD."""
    prompt = max(0, int(input_tokens))
    thoughts = max(0, int(thoughts_tokens))
    cached = max(0, int(cached_tokens))
    billable_output = max(0, int(output_tokens)) + thoughts
    billable_input = max(0, prompt - cached) if cached else prompt
    input_rate, output_rate = rates_for_model(model)
    # Cached input ~10% of input rate when present (Gemini flash-lite style).
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
        "source": source,
    }


def usage_from_gemini_metadata(model: str, meta: dict | None) -> dict:
    """Turn Gemini usageMetadata into tokens + USD. Prefer API counts only."""
    meta = meta if isinstance(meta, dict) else {}
    return usage_from_tokens(
        model,
        input_tokens=int(meta.get("promptTokenCount") or 0),
        output_tokens=int(meta.get("candidatesTokenCount") or 0),
        thoughts_tokens=int(meta.get("thoughtsTokenCount") or 0),
        cached_tokens=int(meta.get("cachedContentTokenCount") or 0),
        source="gemini_usage_metadata",
    )


def usage_from_openai_usage(model: str, usage: dict | None) -> dict:
    """Turn OpenAI chat.completions usage into tokens + USD."""
    usage = usage if isinstance(usage, dict) else {}
    return usage_from_tokens(
        model,
        input_tokens=int(usage.get("prompt_tokens") or 0),
        output_tokens=int(usage.get("completion_tokens") or 0),
        source="openai_usage",
    )


def reserve_usd_for_call(model: str, max_output_tokens: int) -> float:
    """Worst-case USD for one call if the model fills max_output_tokens."""
    input_rate, output_rate = rates_for_model(model)
    input_pad = 2_000
    return (
        input_pad * input_rate / 1_000_000
        + max(0, int(max_output_tokens)) * output_rate / 1_000_000
    )


# Flat per-image USD estimates (~€0.05 target).
_IMAGE_COST_USD: dict[str, float] = {
    "imagen-4.0-generate-001": 0.04,
    "imagen-4.0-fast-generate-001": 0.02,
    "imagen-3.0-generate-002": 0.03,
    "gpt-image-1": 0.07,
    "gpt-image-1-mini": 0.036,
    "dall-e-3": 0.04,
    "fake-image": 0.0,
}


def image_cost_usd(model: str, *, quality: str | None = None) -> float:
    key = (model or "").strip().lower().removeprefix("models/")
    if key.startswith("gpt-image-1") and not key.startswith("gpt-image-1-mini"):
        q = (quality or "medium").strip().lower()
        if q == "low":
            return 0.02
        if q == "high":
            return 0.19
        return 0.07
    if key in _IMAGE_COST_USD:
        return _IMAGE_COST_USD[key]
    for prefix, cost in _IMAGE_COST_USD.items():
        if key.startswith(prefix):
            return cost
    return 0.05


def usage_from_image_cost(model: str, cost_usd: float) -> dict:
    """Bill a fixed per-image cost (no token counts)."""
    return {
        "model": model,
        "input_tokens": 0,
        "output_tokens": 0,
        "thoughts_tokens": 0,
        "cached_tokens": 0,
        "estimated_cost_usd": max(0.0, float(cost_usd)),
        "source": "image_flat_rate",
    }


def reserve_usd_for_image(model: str, *, quality: str | None = None) -> float:
    return image_cost_usd(model, quality=quality)
