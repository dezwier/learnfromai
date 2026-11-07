from __future__ import annotations

from fastapi import FastAPI, Request
from fastapi.exceptions import RequestValidationError
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse

from app.api.v1.router import router
from app.core.config import get_settings
from app.core.errors import AppError
from app.core.logging import configure_logging, setup_sentry
from app.model_registry import register_models


def create_app() -> FastAPI:
    register_models()
    settings = get_settings()
    configure_logging()
    setup_sentry(settings.sentry_dsn)
    app = FastAPI(title="Adaptive Mastery", version="0.1.0")
    app.add_middleware(
        CORSMiddleware,
        allow_origins=settings.cors_origin_list or ["*"],
        allow_credentials=True,
        allow_methods=["*"],
        allow_headers=["*"],
    )

    @app.exception_handler(AppError)
    def app_error(_request: Request, exc: AppError) -> JSONResponse:
        return JSONResponse(status_code=exc.status_code, content={"code": exc.code, "message": exc.message, "details": exc.details})

    @app.exception_handler(RequestValidationError)
    def validation_error(_request: Request, exc: RequestValidationError) -> JSONResponse:
        return JSONResponse(
            status_code=422,
            content={"code": "VALIDATION_ERROR", "message": "Request validation failed", "details": {"errors": exc.errors()}},
        )

    @app.get("/health")
    def health() -> dict:
        return {"status": "ok"}

    app.include_router(router, prefix=settings.api_v1_prefix)
    return app


app = create_app()
