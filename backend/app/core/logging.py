from __future__ import annotations

import json
import logging
import sys

from app.core.time import utcnow


class JsonFormatter(logging.Formatter):
    def format(self, record: logging.LogRecord) -> str:
        payload = {
            "ts": utcnow().isoformat(),
            "level": record.levelname,
            "logger": record.name,
            "message": record.getMessage(),
        }
        if record.exc_info:
            payload["exc"] = self.formatException(record.exc_info)
        return json.dumps(payload, default=str)


def configure_logging() -> None:
    root = logging.getLogger()
    if getattr(root, "_adaptive_mastery_configured", False):
        return
    root.setLevel(logging.INFO)
    handler = logging.StreamHandler(sys.stdout)
    handler.setFormatter(JsonFormatter())
    root.handlers = [handler]
    root._adaptive_mastery_configured = True  # type: ignore[attr-defined]


def setup_sentry(dsn: str) -> bool:
    if not dsn:
        return False
    import sentry_sdk

    sentry_sdk.init(dsn=dsn, traces_sample_rate=0.0, send_default_pii=False)
    return True
