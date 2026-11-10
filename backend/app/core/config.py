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
    gemini_model: str = "gemini-2.0-flash"
    gemini_temperature: float = 0.0
    cors_origins: str = "http://localhost:8080"
    sentry_dsn: str = ""
    llm_daily_tokens_user_limit: int = 200_000
    graph_expansion_max_nodes: int = 80
    job_worker_concurrency: int = 2
    job_lease_seconds: int = 60
    job_max_attempts: int = 5
    job_idle_seconds: float = 1.0
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
