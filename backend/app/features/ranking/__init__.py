"""User–tile affinity and job ranking for HUD + daily cron.

Formula (weights from Settings; soft decay only — never hard-cap to zero):

  recency(age_days) = exp(-ln(2) * age_days / half_life_days)

  affinity(u, t) = (
      w_focus   * focus_count
    + w_open    * open_count
    + w_learned * 1_if_any_learn_or_check
    + w_packs   * completed_pack_count
    + w_new     * recency(days_since_node_created)
  ) * recency(days_since_last_event_on_tile)

  tile_affinity(t)  = sum over users of affinity(u, t)
  neighbor_score(t) = tile_affinity(t) / (1 + w_neighbor_penalty * neighbor_count)
  learn_score(t)    = tile_affinity(t) / (1 + w_pack_penalty * pack_count)

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
