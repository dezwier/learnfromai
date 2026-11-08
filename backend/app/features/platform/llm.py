from __future__ import annotations

import json
import logging
import re
from typing import Protocol
from uuid import UUID

import httpx
from sqlmodel import Session, func, select

from app.core.config import get_settings
from app.core.errors import generation_unavailable
from app.core.time import utcnow
from app.features.knowledge_graph.identity import canonical_key_for
from app.features.platform.models import LlmUsage

logger = logging.getLogger(__name__)

PROMPT_GRAPH = "graph_branch_v2"
INPUT_USD_PER_TOKEN = 0.10 / 1_000_000
OUTPUT_USD_PER_TOKEN = 0.40 / 1_000_000


class LLMProvider(Protocol):
    name: str

    def propose_graph_branch(self, context: dict) -> tuple[dict, dict]: ...


def _usage(model: str, input_tokens: int = 12, output_tokens: int = 24) -> dict:
    return {
        "model": model,
        "input_tokens": input_tokens,
        "output_tokens": output_tokens,
        "estimated_cost_usd": input_tokens * INPUT_USD_PER_TOKEN + output_tokens * OUTPUT_USD_PER_TOKEN,
    }


def _node(temp_id: str, title: str, summary: str) -> dict:
    return {
        "temp_id": temp_id,
        "title": title,
        "summary": summary,
        "canonical_key": canonical_key_for(title),
    }


def _contains(parent: str, child: str) -> dict:
    return {"from": parent, "to": child, "type": "contains", "is_primary_parent": True}


def _outline(subject: str) -> tuple[list[dict], list[dict]]:
    """A connected branch: three areas, two children each, plus cross edges."""
    areas = [
        (
            f"Foundations of {subject}",
            f"Core ideas in {subject}.",
            [
                (f"Definitions in {subject}", f"The terms {subject} uses."),
                (f"Examples of {subject}", f"Concrete cases of {subject}."),
            ],
        ),
        (
            f"Methods of {subject}",
            f"How to work with {subject}.",
            [
                (f"Procedures for {subject}", f"The usual steps in {subject}."),
                (f"Tools for {subject}", f"What you use for {subject}."),
            ],
        ),
        (
            f"Applications of {subject}",
            f"Where {subject} is used.",
            [
                (f"Use cases of {subject}", f"Typical situations for {subject}."),
                (f"Limits of {subject}", f"Where {subject} stops applying."),
            ],
        ),
    ]
    nodes = [_node("root", subject, f"The subject of {subject}.")]
    edges = []
    for index, (title, summary, children) in enumerate(areas):
        area_id = f"a{index}"
        nodes.append(_node(area_id, title, summary))
        edges.append(_contains("root", area_id))
        for child_index, (child_title, child_summary) in enumerate(children):
            child_id = f"a{index}c{child_index}"
            nodes.append(_node(child_id, child_title, child_summary))
            edges.append(_contains(area_id, child_id))
    edges.append({"from": "a0", "to": "a1", "type": "prerequisite", "is_primary_parent": False})
    edges.append({"from": "a1", "to": "a2", "type": "related", "is_primary_parent": False})
    return nodes, edges


class FakeLLMProvider:
    name = "fake"

    def propose_graph_branch(self, context: dict) -> tuple[dict, dict]:
        instruction = str(context.get("instruction") or "").strip()
        topic = str(context.get("topic") or "").strip()
        subject = instruction or topic or "Topic"
        nodes, edges = _outline(subject)
        return (
            {
                "schema_version": 1,
                "prompt_version": PROMPT_GRAPH,
                "nodes": nodes,
                "edges": edges,
                "truncated": False,
            },
            _usage("fake"),
        )


class GeminiProvider:
    name = "gemini"

    def __init__(self) -> None:
        settings = get_settings()
        self.api_key = settings.google_gemini_api_key
        self.model = settings.gemini_model
        self.temperature = settings.gemini_temperature

    def propose_graph_branch(self, context: dict) -> tuple[dict, dict]:
        prompt = (
            "Extend one shared knowledge graph. Return JSON with nodes and edges only. "
            "Cover the user's request exhaustively: every distinct subtopic a careful outline needs, "
            "usually two or three levels when the subject has real children. "
            "Use contains for hierarchy, prerequisite when one idea must be known before another, "
            "and related for cross-links. Every new node except the branch root must be the target of a contains edge. "
            "Reuse an existing node by copying its concept_id and canonical_key instead of inventing a duplicate. "
            "Do not recreate the parent. Do not emit practice nodes, structure nodes, or origins nodes. "
            "temp_id values are local to this response. Edge endpoints are a temp_id or an existing concept_id.\n"
            + json.dumps(context)
        )
        return self._json(prompt, PROMPT_GRAPH)

    def _json(self, prompt: str, prompt_version: str) -> tuple[dict, dict]:
        if not self.api_key:
            raise generation_unavailable("GOOGLE_GEMINI_API_KEY is not configured")
        url = (
            "https://generativelanguage.googleapis.com/v1beta/models/"
            f"{self.model}:generateContent?key={self.api_key}"
        )
        body = {
            "contents": [{"role": "user", "parts": [{"text": prompt}]}],
            "generationConfig": {
                "temperature": self.temperature,
                "responseMimeType": "application/json",
                "maxOutputTokens": 8192,
            },
        }
        last_error: Exception | None = None
        for attempt in range(1, 4):
            try:
                with httpx.Client(timeout=60) as client:
                    response = client.post(url, json=body)
                response.raise_for_status()
                payload = response.json()
                text = payload["candidates"][0]["content"]["parts"][0]["text"]
                parsed = json.loads(_strip_fences(text))
                parsed.setdefault("schema_version", 1)
                parsed.setdefault("prompt_version", prompt_version)
                meta = payload.get("usageMetadata") or {}
                usage = _usage(
                    self.model,
                    int(meta.get("promptTokenCount") or 0),
                    int(meta.get("candidatesTokenCount") or 0),
                )
                return parsed, usage
            except (httpx.HTTPError, KeyError, json.JSONDecodeError, IndexError) as exc:
                last_error = exc
                body["generationConfig"]["maxOutputTokens"] = min(16384, 8192 * (2 ** (attempt - 1)))
                logger.info("gemini retry %s: %s", attempt, type(exc).__name__)
        raise generation_unavailable("Gemini did not return valid JSON") from last_error


def _strip_fences(text: str) -> str:
    stripped = text.strip()
    if stripped.startswith("```"):
        stripped = re.sub(r"^```(?:json)?", "", stripped).strip()
        stripped = re.sub(r"```$", "", stripped).strip()
    return stripped


def get_provider() -> LLMProvider:
    if get_settings().llm_provider == "fake":
        return FakeLLMProvider()
    return GeminiProvider()


def record_usage(
    session: Session,
    *,
    user_id: UUID | None,
    job_id: UUID | None,
    task: str,
    provider: str,
    usage: dict,
) -> None:
    session.add(
        LlmUsage(
            user_id=user_id,
            job_id=job_id,
            task=task,
            provider=provider,
            model=str(usage.get("model") or provider),
            input_tokens=int(usage.get("input_tokens") or 0),
            output_tokens=int(usage.get("output_tokens") or 0),
            estimated_cost_usd=float(usage.get("estimated_cost_usd") or 0),
        )
    )


def tokens_used_today(session: Session, user_id: UUID) -> int:
    start = utcnow().replace(hour=0, minute=0, second=0, microsecond=0)
    total = session.exec(
        select(func.coalesce(func.sum(LlmUsage.input_tokens + LlmUsage.output_tokens), 0)).where(
            LlmUsage.user_id == user_id,
            LlmUsage.created_at >= start,
        )
    ).one()
    return int(total)


def assert_user_quota(session: Session, user_id: UUID) -> None:
    from app.core.errors import rate_limited

    if tokens_used_today(session, user_id) >= get_settings().llm_daily_tokens_user_limit:
        raise rate_limited()
