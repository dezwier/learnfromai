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
from app.features.knowledge_graph.identity import canonical_key_for, explanation_covers
from app.features.platform.encyclopedia import article_graph
from app.features.platform.models import LlmUsage

logger = logging.getLogger(__name__)

PROMPT_GRAPH = "graph_branch_v3"
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


def _branch(nodes: list[dict], edges: list[dict] | None = None) -> dict:
    return {
        "schema_version": 1,
        "prompt_version": PROMPT_GRAPH,
        "nodes": nodes,
        "edges": edges or [],
        "truncated": False,
    }


class FakeLLMProvider:
    name = "fake"

    def propose_graph_branch(self, context: dict) -> tuple[dict, dict]:
        """One node for this request. Nothing is filled in from a fixed outline."""
        instruction = str(context.get("instruction") or "").strip()
        parent_title = str(context.get("parent_title") or "").strip()
        subject = instruction or parent_title or "Topic"
        parent_level = context.get("parent_level")
        proposed = 0 if parent_level is None else int(parent_level) + 1
        for node in context.get("existing") or []:
            if not isinstance(node, dict):
                continue
            explanation = str(node.get("explanation") or "")
            level = int(node.get("level") or 0)
            if explanation_covers(explanation, instruction) and proposed <= level:
                title = str(node.get("title") or subject)
                reused = {
                    "temp_id": "reused",
                    "concept_id": node.get("concept_id"),
                    "title": title,
                    "summary": node.get("summary") or "",
                    "explanation": explanation,
                    "level": level,
                    "canonical_key": node.get("canonical_key") or canonical_key_for(title),
                }
                return _branch([reused]), _usage("fake")
        explanation = f"Covers the range of {subject}."
        return _branch(
            [
                {
                    "temp_id": "requested",
                    "title": subject,
                    "summary": subject,
                    "explanation": explanation,
                    "level": proposed,
                    "canonical_key": canonical_key_for(subject),
                }
            ]
        ), _usage("fake")


class EncyclopediaProvider:
    name = "encyclopedia"

    def propose_graph_branch(self, context: dict) -> tuple[dict, dict]:
        """The real parts of the requested topic, taken from its encyclopedia article."""
        built = article_graph(context)
        branch = _branch(built["nodes"], built["edges"])
        branch["truncated"] = bool(built["truncated"])
        return branch, _usage("encyclopedia", 0, 0)


class GeminiProvider:
    name = "gemini"

    def __init__(self) -> None:
        settings = get_settings()
        self.api_key = settings.google_gemini_api_key
        self.model = settings.gemini_model
        self.temperature = settings.gemini_temperature

    def propose_graph_branch(self, context: dict) -> tuple[dict, dict]:
        prompt = (
            "Extend one shared knowledge graph from this request. Return JSON with nodes and edges only. "
            "Cover the request exhaustively: the subject plus the real subtopics a full treatment of that subject needs, "
            "several levels deep, not a single layer of children. "
            "Each title is short and names the subject, for example a section called classification becomes "
            "'Classification of dinosaurs' when the subject is dinosaurs. "
            "Use the actual parts of the subject. Do not substitute a generic outline such as foundations, methods, and applications. "
            "Each node has title, summary, explanation, and level. "
            "level 0 is the broadest topic and larger numbers are more specific parts. "
            "explanation is several sentences that state the range the node covers, so a later request can tell "
            "whether an idea is already included. "
            "summary is one short line. "
            "Reuse an existing node when its explanation already covers the idea: copy its concept_id, canonical_key, "
            "level, and explanation, and do not invent a duplicate. "
            "Add a new node only for a part outside every existing explanation, one level deeper than the node that contains it. "
            "Use contains for that hierarchy, prerequisite when one idea must be known before another, and related for a cross-link. "
            "Every new node except the branch root must be the target of a contains edge. "
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
    settings = get_settings()
    # Tests pin the one-node provider. Everywhere else, a request becomes the
    # article's real topic graph, or Gemini when a key is configured.
    if settings.environment == "test":
        return FakeLLMProvider()
    if settings.llm_provider == "gemini" and settings.google_gemini_api_key:
        return GeminiProvider()
    return EncyclopediaProvider()


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
