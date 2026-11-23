"""Neighbor and learn job rankings from aggregated tile affinity + fill term."""

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


def _fill_factor(have: int, desired: int) -> float:
    """(desired - have) / desired, clamped to [0, 1]."""
    if desired <= 0:
        return 0.0
    return max(0.0, min(1.0, (desired - have) / float(desired)))


def neighbor_job_scores(
    session: Session,
    *,
    settings: Settings | None = None,
    aggregated: dict | None = None,
) -> list[dict]:
    """Rank tiles for expand_neighborhood.

    score = aggregated_affinity + w_fill * (desired_neighbors - n) / desired_neighbors
    Pass ``aggregated`` from ``aggregate_tile_affinity`` to avoid a second pass.
    """
    s = settings or get_settings()
    desired = int(s.cron_neighbor_budget_total)
    tiles = aggregated if aggregated is not None else aggregate_tile_affinity(session, settings=s)
    ranked: list[dict] = []
    for nid, row in tiles.items():
        neighbors = _direct_neighbor_count(session, nid)
        if neighbors >= desired:
            continue
        affinity = float(row["affinity"])
        fill = _fill_factor(neighbors, desired)
        fill_term = float(s.cron_neighbor_w_fill * fill)
        ranked.append(
            {
                "node_id": nid,
                "name": row["name"],
                "tile_affinity": affinity,
                "neighbor_count": neighbors,
                "fill_factor": round(fill, 6),
                "fill_term": round(fill_term, 6),
                "top_user_id": row["top_user_id"],
                "score": affinity + fill_term,
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
    aggregated: dict | None = None,
) -> list[dict]:
    """Rank tiles for expand_content.

    score = aggregated_affinity + w_fill * (desired_packs - packs) / desired_packs
    Pass ``aggregated`` from ``aggregate_tile_affinity`` to avoid a second pass.
    """
    s = settings or get_settings()
    desired_packs = int(s.cron_learn_desired_packs)
    tiles = aggregated if aggregated is not None else aggregate_tile_affinity(session, settings=s)
    ranked: list[dict] = []
    for nid, row in tiles.items():
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
        fill = _fill_factor(packs, desired_packs)
        fill_term = float(s.cron_learn_w_fill * fill)
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
                "fill_factor": round(fill, 6),
                "fill_term": round(fill_term, 6),
                "top_user_id": row["top_user_id"],
                "score": affinity + fill_term,
            }
        )
    ranked.sort(key=lambda r: (-r["score"], r["name"].lower()))
    return ranked
