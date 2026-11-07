from __future__ import annotations


class AppError(Exception):
    def __init__(
        self,
        code: str,
        message: str,
        status_code: int = 400,
        details: dict | None = None,
    ) -> None:
        super().__init__(message)
        self.code = code
        self.message = message
        self.status_code = status_code
        self.details = details or {}


def invalid_graph(reason: str, **details: object) -> AppError:
    payload = {"reason": reason, **details}
    return AppError("INVALID_GRAPH", "Graph failed validation", 422, payload)


def graph_stale(current_release_id: str) -> AppError:
    return AppError(
        "GRAPH_STALE",
        "The graph changed since this edit started",
        409,
        {
            "current_release_id": current_release_id,
            "rebase": "Reload the current release and submit the proposal again.",
        },
    )


def forbidden(message: str = "Forbidden") -> AppError:
    return AppError("FORBIDDEN", message, 403)


def not_found(message: str = "Not found") -> AppError:
    return AppError("NOT_FOUND", message, 404)


def migration_pending(migration_id: str | None = None) -> AppError:
    return AppError(
        "MIGRATION_PENDING",
        "Learner release activation is not complete",
        409,
        {"migration_id": migration_id} if migration_id else {},
    )


def rate_limited(message: str = "Generation quota exceeded") -> AppError:
    return AppError("RATE_LIMITED", message, 429)


def generation_unavailable(message: str = "The model is unavailable") -> AppError:
    return AppError("GENERATION_UNAVAILABLE", message, 503)
