from datetime import timedelta

from sqlmodel import Session as DBSession

from app.core.db import engine
from app.core.logging import setup_sentry
from app.core.time import utcnow
from app.features.platform.jobs import claim_next, enqueue, retry_later


def test_job_claim_skip_locked(session, user):
    enqueue(session, job_type="noop", user_id=user.id, payload={"n": 1})
    enqueue(session, job_type="noop", user_id=user.id, payload={"n": 2})
    session.commit()
    with DBSession(engine, expire_on_commit=False) as first, DBSession(engine, expire_on_commit=False) as second:
        claimed_a = claim_next(first)
        claimed_b = claim_next(second)
        assert claimed_a is not None and claimed_b is not None
        assert claimed_a[0].id != claimed_b[0].id


def test_sentry_stays_off_without_dsn():
    assert setup_sentry("") is False


def test_expired_lease_is_reclaimed_and_backoff_hides_the_retry(session, user):
    job = enqueue(session, job_type="noop", user_id=user.id, payload={})
    session.commit()
    claimed, token = claim_next(session)
    claimed.lease_until = utcnow() - timedelta(seconds=1)
    session.add(claimed)
    session.commit()
    again, token_2 = claim_next(session)
    assert again.id == job.id
    assert token_2 != token
    retry_later(session, again.id, token_2, "TRANSIENT", "later")
    assert claim_next(session) is None
