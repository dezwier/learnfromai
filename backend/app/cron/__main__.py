"""Entrypoint: python -m app.cron"""

from __future__ import annotations

import sys

from sqlmodel import Session

from app.core.db import engine
from app.features.ranking.cron_run import run_daily_cron
from app.model_registry import register_models


def main() -> int:
    register_models()
    with Session(engine, expire_on_commit=False) as session:
        try:
            run = run_daily_cron(session)
            session.commit()
            print(
                f"cron ok status={run.status} "
                f"neighbors={len(run.neighbor_jobs or [])} "
                f"learn={len(run.learn_jobs or [])}"
            )
            return 0
        except Exception as exc:  # noqa: BLE001
            session.commit()
            print(f"cron failed: {exc}", file=sys.stderr)
            return 1


if __name__ == "__main__":
    raise SystemExit(main())
