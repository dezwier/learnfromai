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
from app.features.platform.models import LlmUsage

logger = logging.getLogger(__name__)

PROMPT_GRAPH = "graph_branch_v1"
PROMPT_UPDATE = "graph_update_v1"
PROMPT_ACTIVITY = "activity_v1"
PROMPT_GRADE = "grade_v1"
PROMPT_MAP = "objective_map_v1"
INPUT_USD_PER_TOKEN = 0.10 / 1_000_000
OUTPUT_USD_PER_TOKEN = 0.40 / 1_000_000


class LLMProvider(Protocol):
    name: str

    def propose_graph_branch(self, context: dict) -> tuple[dict, dict]: ...

    def propose_graph_update(self, context: dict) -> tuple[dict, dict]: ...

    def generate_activity(self, context: dict) -> tuple[dict, dict]: ...

    def grade_open_answer(self, context: dict) -> tuple[dict, dict]: ...

    def propose_objective_mapping(self, context: dict) -> tuple[dict, dict]: ...


def _shares_fossil(topic: str) -> bool:
    folded = topic.lower()
    return "dino" in folded or "paleont" in folded


def _node(temp_id: str, title: str, summary: str, statement: str, key: str | None = None) -> dict:
    node = {
        "temp_id": temp_id,
        "title": title,
        "summary": summary,
        "knowledge_type": "timeless_foundation",
        "objectives": [
            {
                "temp_id": f"{temp_id}-obj",
                "statement": statement,
                "cognitive_dimension": "understanding",
            }
        ],
    }
    if key:
        node["canonical_key"] = key
    return node


def _contains(parent: str, child: str) -> dict:
    return {"from": parent, "to": child, "type": "contains", "is_primary_parent": True}


def _life_branch(include_paleontology: bool) -> tuple[list[dict], list[dict]]:
    nodes = [
        _node("vertebrates", "Vertebrates", "Animals with a backbone.", "Explain what makes an animal a vertebrate"),
        _node("dinosaurs", "Dinosaurs", "Archosaurs that dominated land ecosystems for over 150 million years.", "Explain what a dinosaur is"),
        _node("mammals", "Mammals", "Vertebrates that nurse their young.", "Explain what makes an animal a mammal"),
        _node("birds", "Birds", "Feathered vertebrates, the living dinosaur lineage.", "Explain how birds relate to dinosaurs"),
        _node("theropods", "Theropods", "Mostly bipedal dinosaurs, including tyrannosaurs.", "Name what distinguishes a theropod"),
        _node("sauropods", "Sauropods", "Long-necked herbivorous dinosaurs.", "Describe a sauropod body plan"),
        _node("ornithischians", "Ornithischians", "Dinosaurs with a bird-like pelvis, mostly herbivores.", "Contrast ornithischians with theropods"),
        _node("fossil", "Fossil", "Preserved remains used to reconstruct past life.", "Explain what a fossil records", "fossil"),
    ]
    edges = [
        _contains("vertebrates", "dinosaurs"),
        _contains("vertebrates", "mammals"),
        _contains("vertebrates", "birds"),
        _contains("dinosaurs", "theropods"),
        _contains("dinosaurs", "sauropods"),
        _contains("dinosaurs", "ornithischians"),
        {"from": "dinosaurs", "to": "fossil", "type": "related", "is_primary_parent": False},
    ]
    if include_paleontology:
        nodes.append(
            _node("paleontology", "Paleontology", "The study of ancient life through fossils.", "Explain what paleontology studies")
        )
        edges.append(_contains("paleontology", "fossil"))
        edges.append({"from": "paleontology", "to": "dinosaurs", "type": "related", "is_primary_parent": False})
    return nodes, edges


def _refined_branch(topic: str) -> tuple[list[dict], list[dict]]:
    """A subject and the more specific subjects under it. Never a 'structure' or 'origins' label."""
    title, children = _outline_for(topic)
    nodes = [_node("root", title, f"The subject of {title}.", f"Explain {title}")]
    edges: list[dict] = []
    for index, (child_title, summary, grands) in enumerate(children):
        child_id = f"c{index}"
        child = _node(child_id, child_title, summary, f"Explain {child_title}")
        child["parent"] = "root"
        nodes.append(child)
        edges.append(_contains("root", child_id))
        for grand_index, (grand_title, grand_summary) in enumerate(grands):
            grand_id = f"c{index}g{grand_index}"
            grand = _node(grand_id, grand_title, grand_summary, f"Explain {grand_title}")
            grand["parent"] = child_id
            nodes.append(grand)
            edges.append(_contains(child_id, grand_id))
    return nodes, edges


def _outline_for(topic: str) -> tuple[str, list[tuple[str, str, list[tuple[str, str]]]]]:
    folded = topic.lower()
    best: tuple[str, list[tuple[str, str, list[tuple[str, str]]]]] | None = None
    best_keys = -1
    for keys, title, children in _OUTLINES:
        if all(key in folded for key in keys) and len(keys) > best_keys:
            best = (title, children)
            best_keys = len(keys)
    if best is not None:
        return best
    name = topic.strip() or "Topic"
    if name.islower():
        name = name[:1].upper() + name[1:]
    return name, [
        (f"Core ideas in {name}", f"The ideas {name} is built from.", []),
        (f"Examples of {name}", f"Concrete cases of {name}.", []),
        (f"How {name} is used", f"Where {name} shows up.", []),
    ]


_OUTLINES: list[tuple[tuple[str, ...], str, list[tuple[str, str, list[tuple[str, str]]]]]] = [
    (
        ("childhood", "nutrition"),
        "Childhood nutrition",
        [
            (
                "Breastfeeding",
                "Milk feeding in the first months of life.",
                [("Colostrum", "The first milk, produced just after birth."), ("Exclusive breastfeeding", "Milk alone through the early months.")],
            ),
            (
                "Complementary feeding",
                "Foods added beside milk as a child grows.",
                [("Weaning", "The shift from milk toward family food."), ("Food variety", "Different foods that cover a child's needs.")],
            ),
            (
                "Micronutrients",
                "Vitamins and minerals a growing child needs.",
                [("Iron", "A mineral children run short of easily."), ("Vitamin A", "A vitamin tied to vision and immunity.")],
            ),
            (
                "Growth",
                "How feeding shows up in a child's size and strength.",
                [("Stunting", "Being short for one's age after poor nutrition."), ("Wasting", "Being thin for one's height.")],
            ),
        ],
    ),
    (
        ("nutrition",),
        "Nutrition",
        [
            ("Macronutrients", "Protein, fat, and carbohydrate.", [("Protein", "The nutrient used to build tissue."), ("Carbohydrate", "The body's main fuel.")]),
            ("Micronutrients", "Vitamins and minerals.", [("Iron", "A mineral used to carry oxygen."), ("Vitamin D", "A vitamin used in bone growth.")]),
            ("Diet patterns", "How meals fit together over time.", [("Meal balance", "A meal that covers more than one need."), ("Food choice", "Which foods a diet is built from.")]),
        ],
    ),
    (
        ("decision", "tree"),
        "Decision Trees",
        [
            ("Splits", "Questions a tree asks about a feature.", []),
            ("Entropy", "Uncertainty of a label distribution.", []),
            ("Information Gain", "How much a split reduces that uncertainty.", []),
        ],
    ),
]


def _usage(model: str, input_tokens: int = 12, output_tokens: int = 24) -> dict:
    return {
        "model": model,
        "input_tokens": input_tokens,
        "output_tokens": output_tokens,
        "estimated_cost_usd": input_tokens * INPUT_USD_PER_TOKEN + output_tokens * OUTPUT_USD_PER_TOKEN,
    }


class FakeLLMProvider:
    name = "fake"

    def propose_graph_branch(self, context: dict) -> tuple[dict, dict]:
        instruction = str(context.get("instruction") or "").lower()
        parent = context.get("parent_concept_id")
        if parent and ("entropy" in instruction or "splitting" in instruction or "information" in instruction):
            return (
                {
                    "schema_version": 1,
                    "prompt_version": PROMPT_GRAPH,
                    "nodes": [
                        {
                            "temp_id": "entropy",
                            "title": "Entropy",
                            "summary": "Uncertainty of a label distribution.",
                            "parent": parent,
                            "objectives": [
                                {
                                    "temp_id": "entropy-obj",
                                    "statement": "calculate entropy from class frequencies",
                                    "cognitive_dimension": "application",
                                }
                            ],
                        },
                        {
                            "temp_id": "gain",
                            "title": "Information Gain",
                            "summary": "Reduction in entropy from a split.",
                            "parent": parent,
                            "objectives": [
                                {
                                    "temp_id": "gain-obj",
                                    "statement": "compute information gain of a candidate split",
                                    "cognitive_dimension": "application",
                                }
                            ],
                        },
                    ],
                    "edges": [
                        {"from": "entropy", "to": "gain", "type": "prerequisite", "is_primary_parent": False},
                    ],
                    "uncertainties": ["Fixture expansion. Not independently fact-checked."],
                    "sources": [],
                },
                _usage("fake"),
            )
        instruction = str(context.get("instruction") or "").strip()
        topic = str(context.get("topic") or "").strip()
        subject = instruction or topic or "Topic"
        if _shares_fossil(subject):
            nodes, edges = _life_branch("paleont" in subject.lower())
        else:
            nodes, edges = _refined_branch(subject)
        return (
            {
                "schema_version": 1,
                "prompt_version": PROMPT_GRAPH,
                "nodes": nodes,
                "edges": edges,
                "uncertainties": ["Generated by the fixture provider. Not an independent fact check."],
                "sources": [],
            },
            _usage("fake"),
        )

    def propose_graph_update(self, context: dict) -> tuple[dict, dict]:
        return (
            {
                "schema_version": 1,
                "prompt_version": PROMPT_UPDATE,
                "operations": context.get("operations") or [],
                "rationale": "Fixture maintenance proposal.",
                "sources": context.get("sources") or [],
                "uncertainties": [],
            },
            _usage("fake"),
        )

    def generate_activity(self, context: dict) -> tuple[dict, dict]:
        kind = context["kind"]
        statement = context["statement"]
        keyword = context.get("keyword") or statement.split()[0].lower()
        body: dict
        rubric: dict
        if kind == "explain":
            title = str(context.get("concept_title") or "").strip() or statement
            subject = statement.strip().rstrip(".")
            for prefix in ("Explain ", "Describe ", "Name ", "Contrast "):
                if subject.startswith(prefix):
                    subject = subject[len(prefix) :]
                    break
            if subject:
                subject = subject[:1].upper() + subject[1:]
            body = {
                "explanation": f"{title}. {subject}.",
                "analogy": f"One way to picture {title} is as one part of a larger subject.",
                "worked_example": subject or title,
            }
            rubric = {"mode": "none", "dimension": "understanding"}
        elif kind == "multiple_choice":
            body = {
                "prompt": statement,
                "choices": [
                    {"id": "A", "text": statement},
                    {"id": "B", "text": "An unrelated claim"},
                    {"id": "C", "text": "The opposite of the statement"},
                ],
                "answer": {"choice": "A"},
            }
            rubric = {"mode": "exact_choice", "dimension": "recall"}
        elif kind == "apply":
            body = {"prompt": f"Use this idea: {statement}", "answer": {"text": keyword}}
            rubric = {"mode": "keyword", "must_include": [keyword], "dimension": "application"}
        elif kind == "teach_back":
            body = {"prompt": f"Explain in your own words: {statement}", "answer": {"text": keyword}}
            rubric = {"mode": "keyword", "must_include": [keyword], "dimension": "understanding"}
        else:
            body = {"prompt": statement, "answer": {"text": keyword}}
            rubric = {"mode": "keyword", "must_include": [keyword], "dimension": "recall"}
        return (
            {
                "schema_version": 1,
                "prompt_version": PROMPT_ACTIVITY,
                "activity_type": kind,
                "content": body,
                "rubric": rubric,
                "difficulty": context.get("difficulty", 1),
                "sources": [],
                "grounding": "user_custom",
            },
            _usage("fake", 8, 16),
        )

    def grade_open_answer(self, context: dict) -> tuple[dict, dict]:
        needles = [item.lower() for item in context.get("must_include", [])]
        text = str(context.get("answer", {}).get("text") or "").lower()
        if not needles:
            score = 0.5
            results = []
        else:
            results = [{"id": needle, "met": needle in text} for needle in needles]
            score = sum(1 for item in results if item["met"]) / len(results)
        uncertain = score not in {0.0, 1.0}
        return (
            {
                "schema_version": 1,
                "prompt_version": PROMPT_GRADE,
                "score": score,
                "criterion_results": results,
                "next_hint": "" if score == 1 else "Cover the missing criteria.",
                "confidence": 0.45 if uncertain else 0.8,
                "uncertain": uncertain,
                "rationale": "Compared the answer with the rubric terms.",
            },
            _usage("fake", 6, 8),
        )

    def propose_objective_mapping(self, context: dict) -> tuple[dict, dict]:
        return (
            {
                "schema_version": 1,
                "prompt_version": PROMPT_MAP,
                "mappings": context.get("mappings") or [],
            },
            _usage("fake", 4, 4),
        )


class GeminiProvider:
    name = "gemini"

    def __init__(self) -> None:
        settings = get_settings()
        self.api_key = settings.google_gemini_api_key
        self.model = settings.gemini_model
        self.temperature = settings.gemini_temperature

    def propose_graph_branch(self, context: dict) -> tuple[dict, dict]:
        return self._json(
            "Propose a bounded knowledge-graph branch as JSON with nodes, edges, uncertainties, and sources. "
            "Use temp ids only. Do not invent database ids. Nodes are real topics and more specific topics under them, "
            "never a practice node. When an existing concept is the same idea, "
            "reuse its title and canonical_key so the server keeps one node.\n"
            + json.dumps(context),
            PROMPT_GRAPH,
        )

    def propose_graph_update(self, context: dict) -> tuple[dict, dict]:
        return self._json(
            "Propose a graph update as JSON operations. Do not write SQL.\n" + json.dumps(context),
            PROMPT_UPDATE,
        )

    def generate_activity(self, context: dict) -> tuple[dict, dict]:
        return self._json(
            "Generate one learning activity as JSON with content, rubric, difficulty, and sources. "
            "Ground factual claims in the provided sources or mark grounding user_custom.\n"
            + json.dumps(context),
            PROMPT_ACTIVITY,
        )

    def grade_open_answer(self, context: dict) -> tuple[dict, dict]:
        return self._json(
            "Grade the answer against the rubric. Return JSON score, criterion_results, next_hint, "
            "confidence, uncertain, rationale. Do not include hidden chain-of-thought.\n" + json.dumps(context),
            PROMPT_GRADE,
        )

    def propose_objective_mapping(self, context: dict) -> tuple[dict, dict]:
        return self._json(
            "Propose objective mappings as JSON. Use only ids present in the input.\n" + json.dumps(context),
            PROMPT_MAP,
        )

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
                "maxOutputTokens": 2048,
            },
        }
        last_error: Exception | None = None
        for attempt in range(1, 4):
            try:
                with httpx.Client(timeout=30) as client:
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
                body["generationConfig"]["maxOutputTokens"] = 2048 * (2 ** (attempt - 1))
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
