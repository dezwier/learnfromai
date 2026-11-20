"""Neighbor and learn job rankings from aggregated tile affinity."""

from __future__ import annotations

from uuid import UUID

from sqlmodel import Session

from app.core.config import Settings, get_settings
from app.features.content.models import CONTENT_KINDS, DEFAULT_BAND, RECIPE_VERSION
from app.features.content.service import (
    first_incomplete_pack,
    missing_content_kinds,
    next_pack_index,
    pack_indexes,
)
from app.features.knowledge_graph.neighborhood.constants import BUCKET_RELATION, relation_counts
from app.features.ranking.affinity import aggregate_tile_affinity


def _direct_neighbor_count(session: Session, node_id: UUID) -> int:
    have = relation_counts(session, node_id)
    return sum(int(have.get(bucket, 0)) for bucket in BUCKET_RELATION)


def _pack_count(
    session: Session,
    node_id: UUID,
    *,
    band: str = DEFAULT_BAND,
    recipe_version: int = RECIPE_VERSION,
) -> int:
    return len(pack_indexes(session, node_id, band=band, recipe_version=recipe_version))


def neighbor_job_scores(
    session: Session,
    *,
    settings: Settings | None = None,
) -> list[dict]:
    """Rank tiles for expand_neighborhood. Soft neighbor-count penalty; skip if complete."""
    s = settings or get_settings()
    budget = int(s.cron_neighbor_budget_total)
    aggregated = aggregate_tile_affinity(session, settings=s)
    ranked: list[dict] = []
    for nid, row in aggregated.items():
        neighbors = _direct_neighbor_count(session, nid)
        if neighbors >= budget:
            continue
        score = float(row["affinity"]) / (
            1.0 + s.cron_neighbor_w_count_penalty * neighbors
        )
        ranked.append(
            {
                "node_id": nid,
                "name": row["name"],
                "tile_affinity": float(row["affinity"]),
                "neighbor_count": neighbors,
                "top_user_id": row["top_user_id"],
                "score": score,
            }
        )
    ranked.sort(key=lambda r: (-r["score"], r["name"].lower()))
    return ranked


def learn_job_scores(
    session: Session,
    *,
    settings: Settings | None = None,
    band: str = DEFAULT_BAND,
    recipe_version: int = RECIPE_VERSION,
) -> list[dict]:
    """Rank tiles for expand_content. Soft pack-count penalty; include next pack target."""
    s = settings or get_settings()
    aggregated = aggregate_tile_affinity(session, settings=s)
    ranked: list[dict] = []
    for nid, row in aggregated.items():
        packs = _pack_count(session, nid, band=band, recipe_version=recipe_version)
        incomplete = first_incomplete_pack(
            session, nid, band=band, recipe_version=recipe_version
        )
        if incomplete is not None:
            pack_index = incomplete
            missing = missing_content_kinds(
                session,
                nid,
                pack_index=pack_index,
                band=band,
                recipe_version=recipe_version,
            )
            new_pack = False
        elif packs == 0:
            pack_index = 1
            missing = list(CONTENT_KINDS)
            new_pack = False
        else:
            # All existing packs complete → generate next pack.
            pack_index = next_pack_index(
                session, nid, band=band, recipe_version=recipe_version
            )
            missing = list(CONTENT_KINDS)
            new_pack = True
        if not missing:
            continue
        neighbors = _direct_neighbor_count(session, nid)
        affinity = float(row["affinity"])
        score = (
            affinity
            * (1.0 + s.cron_learn_w_neighbor_boost * neighbors)
            / (1.0 + s.cron_learn_w_pack_penalty * packs)
        )
        ranked.append(
            {
                "node_id": nid,
                "name": row["name"],
                "tile_affinity": affinity,
                "neighbor_count": neighbors,
                "pack_count": packs,
                "pack_index": pack_index,
                "missing_kinds": missing,
                "new_pack": new_pack,
                "top_user_id": row["top_user_id"],
                "score": score,
            }
        )
    ranked.sort(key=lambda r: (-r["score"], r["name"].lower()))
    return ranked
