"""Shared expand coalesce and watched job list."""

from sqlmodel import func, select

from app.features.platform.jobs import claim_next
from app.features.platform.models import GenerationJob, GenerationJobWatcher
from app.workers.handlers import handle


def _run_queued(session):
    claimed = claim_next(session)
    assert claimed is not None
    job, token = claimed
    handle(job.id, token)
    session.expire_all()
    return session.get(GenerationJob, job.id)


def test_two_users_coalesce_same_expand_job(client, auth, other_auth, session):
    first = client.post("/api/v1/knowledge/focus", headers=auth, json={"topic": "dinosaurs"})
    assert first.status_code == 202
    job_id = first.json()["job_id"]
    focus_id = first.json()["focus_node_id"]

    second = client.post(
        "/api/v1/knowledge/focus",
        headers=other_auth,
        json={"node_id": focus_id},
    )
    assert second.status_code == 202
    assert second.json()["job_id"] == job_id
    assert second.json()["focus_node_id"] == focus_id

    jobs = session.exec(select(func.count()).select_from(GenerationJob)).one()
    assert jobs == 1
    watchers = session.exec(select(func.count()).select_from(GenerationJobWatcher)).one()
    assert watchers == 2


def test_list_jobs_returns_watched_active_only(client, auth, other_auth, session):
    first = client.post("/api/v1/knowledge/focus", headers=auth, json={"topic": "dinosaurs"})
    assert first.status_code == 202
    job_id = first.json()["job_id"]

    mine = client.get("/api/v1/jobs?state=queued,running", headers=auth)
    assert mine.status_code == 200
    rows = mine.json()["jobs"]
    assert len(rows) == 1
    assert rows[0]["id"] == job_id
    assert rows[0]["title"]
    assert rows[0]["focus_node_id"]

    other = client.get("/api/v1/jobs?state=queued,running", headers=other_auth)
    assert other.status_code == 200
    assert other.json()["jobs"] == []

    # Other user watches via coalesce.
    client.post(
        "/api/v1/knowledge/focus",
        headers=other_auth,
        json={"node_id": first.json()["focus_node_id"]},
    )
    other2 = client.get("/api/v1/jobs?state=queued,running", headers=other_auth)
    assert len(other2.json()["jobs"]) == 1
    assert other2.json()["jobs"][0]["id"] == job_id

    _run_queued(session)
    after = client.get("/api/v1/jobs?state=queued,running", headers=auth)
    assert after.json()["jobs"] == []


def test_get_job_allows_watcher(client, auth, other_auth, session):
    first = client.post("/api/v1/knowledge/focus", headers=auth, json={"topic": "dinosaurs"})
    job_id = first.json()["job_id"]
    focus_id = first.json()["focus_node_id"]
    client.post("/api/v1/knowledge/focus", headers=other_auth, json={"node_id": focus_id})

    watched = client.get(f"/api/v1/jobs/{job_id}", headers=other_auth)
    assert watched.status_code == 200
    assert watched.json()["id"] == job_id
    assert watched.json()["focus_node_id"] == focus_id
