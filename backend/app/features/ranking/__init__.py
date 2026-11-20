"""User–tile affinity and job ranking for HUD + daily cron.

Weights live on Settings, grouped by use case:

  Affinity:      AFFINITY_W_* / AFFINITY_HALF_LIFE_DAYS
  Neighbor cron: CRON_NEIGHBOR_W_COUNT_PENALTY (+ jobs/day, budget)
  Pack cron:     CRON_LEARN_W_PACK_PENALTY, CRON_LEARN_W_NEIGHBOR_BOOST
  Learn track:   LEARN_TRACK_EXPLOIT_P

  neighbor_score = affinity / (1 + cron_neighbor_w_count_penalty * neighbors)
  learn_score    = affinity * (1 + cron_learn_w_neighbor_boost * neighbors)
                   / (1 + cron_learn_w_pack_penalty * packs)

Collaborative filtering can later replace affinity(u,t) behind the same interface.
"""

from app.features.ranking.affinity import score_user_tiles
from app.features.ranking.cron_run import run_daily_cron
from app.features.ranking.job_scores import neighbor_job_scores, learn_job_scores
from app.features.ranking.models import CronRun

__all__ = [
    "CronRun",
    "learn_job_scores",
    "neighbor_job_scores",
    "run_daily_cron",
    "score_user_tiles",
]
