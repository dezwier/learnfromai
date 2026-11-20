from __future__ import annotations

from functools import lru_cache

from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=".env", extra="ignore")

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

    # Ranking: user–tile affinity + job scores (weights only; no hard caps).
    # affinity(u,t) = (w_focus*focus + w_open*open + w_learned*learned
    #   + w_packs*packs_done + w_new*recency(node_age))
    #   * recency(days_since_last_event)
    # recency(d) = exp(-ln(2)*d/half_life_days)
    # neighbor_score = tile_affinity / (1 + w_neighbor_penalty * neighbors)
    # learn_score    = tile_affinity / (1 + w_pack_penalty * packs)
    rank_w_focus: float = 1.0
    rank_w_open: float = 2.0
    rank_w_learned: float = 3.0
    rank_w_packs: float = 1.0
    rank_w_new: float = 2.0
    rank_half_life_days: float = 14.0
    # Heavier penalties: prefer tiles with few neighbors / few packs.
    rank_w_neighbor_penalty: float = 3.0
    rank_w_pack_penalty: float = 8.0
    # Learning track: P(stay on seed topic when it still has unlearned packs).
    learn_track_exploit_p: float = 0.7
    cron_neighbor_jobs_per_day: int = 5
    cron_learn_jobs_per_day: int = 10
    cron_neighbor_budget_total: int = 16

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
