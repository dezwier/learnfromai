from __future__ import annotations

from functools import lru_cache

from pydantic import AliasChoices, Field
from pydantic_settings import BaseSettings, SettingsConfigDict


def _env(*names: str) -> AliasChoices:
    """Accept new + legacy env names (case-insensitive via settings)."""
    return AliasChoices(*names)


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=".env", extra="ignore", populate_by_name=True)

    environment: str = "development"
    database_url: str = "postgresql+psycopg://desiredewaele@localhost:5432/adaptive_mastery"
    secret_key: str = "dev-only-change-me"
    firebase_service_account_json: str = ""
    firebase_auth_emulator_host: str = ""
    google_gemini_api_key: str = ""
    gemini_model: str = "gemini-3.5-flash-lite"
    gemini_temperature: float = 0.0
    # Native Gemini image model (~$0.034 / 1K square). Imagen predict API is shut down.
    gemini_image_model: str = "gemini-3.1-flash-lite-image"
    openai_api_key: str = ""
    openai_model: str = "gpt-5-mini"
    openai_temperature: float = 0.0
    # gpt-image-1 was shut down Oct 2026; flare + low ≈ near €0.05 target.
    openai_image_model: str = "gpt-image-2.5-flare"
    openai_image_quality: str = "low"
    openai_image_size: str = "1024x1024"
    cors_origins: str = "http://localhost:8080"
    sentry_dsn: str = ""
    llm_daily_tokens_user_limit: int = 1_000_000
    # Hard global daily cap from recorded LLM usage × published rates (≈€3 ≈ $3).
    llm_daily_spend_eur_limit: float = 3.0
    # USD per EUR for the cap (1.0 ≈ treat €1 as $1; raise to stop earlier).
    llm_usd_per_eur: float = 1.0
    graph_expansion_max_nodes: int = 80
    job_worker_concurrency: int = 2
    # Long enough for LLM timeouts + consolidate/merge; progress also renews the lease.
    job_lease_seconds: int = 600
    job_max_attempts: int = 3
    job_idle_seconds: float = 1.0
    # Server default when the user has no llm_provider preference: gemini | openai | fake.
    llm_provider: str = "gemini"
    access_token_expire_minutes: int = 60 * 24 * 7
    api_v1_prefix: str = "/api/v1"
    wikipedia_api_url: str = "https://en.wikipedia.org/w/api.php"
    wikipedia_user_agent: str = "AdaptiveMastery/1.0 (https://github.com/dezwier/learnfromai; knowledge graph)"
    wikipedia_timeout_seconds: float = 20.0
    wikipedia_cache_ttl_days: int = 30
    wikipedia_default_up_depth: int = 1
    wikipedia_default_down_depth: int = 1
    wikipedia_max_depth: int = 2
    wikipedia_max_categories_per_request: int = 200
    wikidata_api_url: str = "https://www.wikidata.org/w/api.php"
    wikidata_sparql_url: str = "https://query.wikidata.org/sparql"
    wikidata_user_agent: str = "AdaptiveMastery/1.0 (https://github.com/dezwier/learnfromai; knowledge graph)"
    wikidata_timeout_seconds: float = 20.0
    wikidata_cache_ttl_days: int = 30
    wikidata_default_up_depth: int = 1
    wikidata_default_down_depth: int = 1
    wikidata_max_depth: int = 2
    wikidata_default_cloud_radius: int = 1
    wikidata_max_cloud_radius: int = 2
    wikidata_max_items_per_request: int = 200

    # --- Affinity (profile map + base tile score for cron) ---
    # Per-user normalized factors, then weighted sum (weights default 1):
    #   interest_norm  = (focus+open) / Σ_tiles (focus+open)          ∈ [0,1]
    #   neighbor_norm  = Σ_neighbors (focus+open) / Σ_tiles (…)       ∈ [0,1]
    #   recency        = linear last focus/open: today→1, ≥span→0.5
    # affinity = w_interest*interest_norm + w_neighbor*neighbor_norm + w_recency*recency
    affinity_w_interest: float = Field(
        default=1.0,
        validation_alias=_env("affinity_w_interest", "AFFINITY_W_INTEREST"),
    )
    affinity_w_neighbor: float = Field(
        default=1.0,
        validation_alias=_env("affinity_w_neighbor", "AFFINITY_W_NEIGHBOR"),
    )
    affinity_w_recency: float = Field(
        default=1.0,
        validation_alias=_env("affinity_w_recency", "AFFINITY_W_RECENCY"),
    )
    # Days over which recency falls linearly from 1.0 to 0.5 (≈3 months).
    affinity_recency_span_days: float = Field(
        default=90.0,
        validation_alias=_env(
            "affinity_recency_span_days",
            "AFFINITY_RECENCY_SPAN_DAYS",
            "AFFINITY_HALF_LIFE_DAYS",
            "RANK_HALF_LIFE_DAYS",
        ),
    )

    # --- Cron: expand-neighborhood job ranking ---
    # neighbor_score = affinity / (1 + w_count_penalty * neighbor_count)
    cron_neighbor_w_count_penalty: float = Field(
        default=3.0,
        validation_alias=_env(
            "cron_neighbor_w_count_penalty",
            "CRON_NEIGHBOR_W_COUNT_PENALTY",
            "RANK_W_NEIGHBOR_PENALTY",
        ),
    )
    cron_neighbor_jobs_per_day: int = 5
    cron_neighbor_budget_total: int = 16

    # --- Cron: expand-content (atomic packs) job ranking ---
    # learn_score = affinity * (1 + w_neighbor_boost * neighbors)
    #               / (1 + w_pack_penalty * packs)
    cron_learn_w_pack_penalty: float = Field(
        default=8.0,
        validation_alias=_env(
            "cron_learn_w_pack_penalty", "CRON_LEARN_W_PACK_PENALTY", "RANK_W_PACK_PENALTY"
        ),
    )
    cron_learn_w_neighbor_boost: float = Field(
        default=0.25,
        validation_alias=_env(
            "cron_learn_w_neighbor_boost",
            "CRON_LEARN_W_NEIGHBOR_BOOST",
            "RANK_W_LEARN_NEIGHBOR_BOOST",
        ),
    )
    cron_learn_jobs_per_day: int = 10

    # --- Learning track (in-app next-card picker) ---
    # P(stay on seed topic when it still has unlearned packs).
    learn_track_exploit_p: float = 0.7

    @property
    def cors_origin_list(self) -> list[str]:
        return [item.strip() for item in self.cors_origins.split(",") if item.strip()]

    @property
    def sqlalchemy_database_url(self) -> str:
        url = self.database_url
        if url.startswith("postgres://"):
            return "postgresql+psycopg://" + url.removeprefix("postgres://")
        if url.startswith("postgresql://"):
            return "postgresql+psycopg://" + url.removeprefix("postgresql://")
        return url


@lru_cache
def get_settings() -> Settings:
    return Settings()
