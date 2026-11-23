"""User–tile affinity and job ranking for HUD + daily cron.

Weights live on Settings (env defaults); admin may override cron fill weights
in ``ranking_config`` (applied via ``effective_ranking_settings``):

  Affinity:      AFFINITY_W_INTEREST / NEIGHBOR / RECENCY + RECENCY_SPAN_DAYS
  Neighbor cron: CRON_NEIGHBOR_W_FILL + CRON_NEIGHBOR_BUDGET_TOTAL (+ jobs/day)
  Pack cron:     CRON_LEARN_W_FILL + CRON_LEARN_DESIRED_PACKS (+ jobs/day)
  Learn track:   LEARN_TRACK_EXPLOIT_P

  neighbor_score = affinity + w_fill * (desired_neighbors - n) / desired_neighbors
  learn_score    = affinity + w_fill * (desired_packs - packs) / desired_packs

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
