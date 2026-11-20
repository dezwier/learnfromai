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
    first = client.post("/api/v1/knowledge/focus", headers=auth, json={"topic": "dinosaurs", "expand": True})
    assert first.status_code == 202
    job_id = first.json()["job_id"]
    focus_id = first.json()["focus_node_id"]

    second = client.post(
        "/api/v1/knowledge/focus",
        headers=other_auth,
        json={"node_id": focus_id, "expand": True},
    )
    assert second.status_code == 202
    assert second.json()["job_id"] == job_id
    assert second.json()["focus_node_id"] == focus_id

    jobs = session.exec(select(func.count()).select_from(GenerationJob)).one()
    assert jobs == 1
    watchers = session.exec(select(func.count()).select_from(GenerationJobWatcher)).one()
    assert watchers == 2


def test_list_jobs_returns_watched_active_only(client, auth, other_auth, session):
    first = client.post("/api/v1/knowledge/focus", headers=auth, json={"topic": "dinosaurs", "expand": True})
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
        json={"node_id": first.json()["focus_node_id"], "expand": True},
    )
    other2 = client.get("/api/v1/jobs?state=queued,running", headers=other_auth)
    assert len(other2.json()["jobs"]) == 1
    assert other2.json()["jobs"][0]["id"] == job_id

    _run_queued(session)
    after = client.get("/api/v1/jobs?state=queued,running", headers=auth)
    assert after.json()["jobs"] == []


def test_get_job_allows_watcher(client, auth, other_auth, session):
    first = client.post("/api/v1/knowledge/focus", headers=auth, json={"topic": "dinosaurs", "expand": True})
    job_id = first.json()["job_id"]
    focus_id = first.json()["focus_node_id"]
    client.post("/api/v1/knowledge/focus", headers=other_auth, json={"node_id": focus_id, "expand": True})

    watched = client.get(f"/api/v1/jobs/{job_id}", headers=other_auth)
    assert watched.status_code == 200
    assert watched.json()["id"] == job_id


def test_different_job_types_parallel_same_type_coalesces(client, auth, other_auth, session):
    focus = client.post(
        "/api/v1/knowledge/focus",
        headers=auth,
        json={"topic": "parallel-types", "expand": True},
    )
    assert focus.status_code == 202
    node_id = focus.json()["focus_node_id"]
    neighbor_job = focus.json()["job_id"]

    content = client.post(
        f"/api/v1/knowledge/nodes/{node_id}/content",
        headers=auth,
        json={"expand": True},
    )
    image = client.post(
        f"/api/v1/knowledge/nodes/{node_id}/image",
        headers=auth,
        json={"generate": True},
    )
    assert content.status_code == 202
    assert image.status_code == 202
    content_job = content.json()["job_id"]
    image_job = image.json()["job_id"]
    assert len({neighbor_job, content_job, image_job}) == 3

    # Same type across users joins the in-flight job.
    again = client.post(
        f"/api/v1/knowledge/nodes/{node_id}/content",
        headers=other_auth,
        json={"expand": True, "new_pack": True},
    )
    assert again.status_code == 202
    assert again.json()["job_id"] == content_job
    assert session.exec(select(func.count()).select_from(GenerationJob)).one() == 3

    listed = client.get(f"/api/v1/knowledge/nodes/{node_id}/jobs", headers=other_auth)
    assert listed.status_code == 200
    types = {row["type"] for row in listed.json()["jobs"]}
    assert types == {"expand_neighborhood", "expand_content", "generate_image"}
    # Listing attaches the caller as a watcher for jobs they had not requested.
    other_jobs = client.get("/api/v1/jobs?state=queued,running", headers=other_auth)
    assert len(other_jobs.json()["jobs"]) == 3
