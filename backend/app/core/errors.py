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


def forbidden(message: str = "Forbidden") -> AppError:
    return AppError("FORBIDDEN", message, 403)


def not_found(message: str = "Not found") -> AppError:
    return AppError("NOT_FOUND", message, 404)


def rate_limited(message: str = "Generation quota exceeded") -> AppError:
    # Terminal: do not burn worker retries once the daily token budget is gone.
    return AppError("RATE_LIMITED", message, 429, {"terminal": True})


def generation_unavailable(message: str = "The model is unavailable", *, terminal: bool = False) -> AppError:
    details = {"terminal": True} if terminal else {}
    return AppError("GENERATION_UNAVAILABLE", message, 503, details)
