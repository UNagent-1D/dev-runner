from datetime import datetime, timezone

import pytest
from fastapi.testclient import TestClient

from main import app, daily, tenant_stats


@pytest.fixture
def client():
    with TestClient(app) as c:
        tenant_stats.clear()
        daily.clear()
        yield c


def test_health(client):
    r = client.get("/health")
    assert r.status_code == 200
    assert r.json() == {"status": "ok"}


def test_root(client):
    r = client.get("/")
    assert r.status_code == 200
    body = r.json()
    assert body["service"] == "compliance"
    assert body["version"] == "2.0"


def test_legacy_chat_requires_tenant_header(client):
    r = client.post("/conversation/chat", json={"message": "hi"})
    assert r.status_code == 400
    assert "X-Tenant-ID" in r.json()["detail"]


def test_legacy_chat_records_resolved_turn(client):
    r = client.post(
        "/conversation/chat",
        json={"message": "hi", "resolved": True},
        headers={"X-Tenant-ID": "demo"},
    )
    assert r.status_code == 200
    body = r.json()
    assert body["bot_resolved"] is True
    stats = tenant_stats["demo"]
    assert stats.total_conversations == 1
    assert stats.successful_chats == 1
    assert stats.messages_user == 1
    assert stats.messages_bot == 1


def test_legacy_chat_unresolved_does_not_count_as_successful(client):
    client.post(
        "/conversation/chat",
        json={"message": "hi", "resolved": False},
        headers={"X-Tenant-ID": "demo"},
    )
    stats = tenant_stats["demo"]
    assert stats.total_conversations == 1
    assert stats.successful_chats == 0


def test_legacy_csat_requires_tenant_header(client):
    r = client.post("/feedback/csat", json={"score": 4})
    assert r.status_code == 400


def test_legacy_csat_running_average(client):
    headers = {"X-Tenant-ID": "demo"}
    r1 = client.post("/feedback/csat", json={"score": 5}, headers=headers)
    r2 = client.post("/feedback/csat", json={"score": 3}, headers=headers)
    assert r1.status_code == 200
    assert r2.status_code == 200
    assert r2.json()["current_avg"] == pytest.approx(4.0)


def test_kpis_empty(client):
    r = client.get("/stats/kpis")
    assert r.status_code == 200
    assert r.json() == {"data": []}


def test_kpis_after_traffic(client):
    headers = {"X-Tenant-ID": "t1"}
    client.post("/conversation/chat", json={"message": "a", "resolved": True}, headers=headers)
    client.post("/conversation/chat", json={"message": "b", "resolved": False}, headers=headers)
    client.post("/feedback/csat", json={"score": 4}, headers=headers)

    r = client.get("/stats/kpis")
    rows = r.json()["data"]
    assert len(rows) == 1
    row = rows[0]
    assert row["tenant_id"] == "t1"
    assert row["total_conversations"] == 2
    assert row["resolution_rate_percent"] == 50.0
    assert row["average_csat"] == 4.0
    assert row["avg_messages_per_conv"] == 2.0


def test_timeseries_default_window_is_seven_days(client):
    r = client.get("/stats/timeseries")
    points = r.json()["data"]
    assert len(points) == 7
    today = datetime.now(timezone.utc).strftime("%Y-%m-%d")
    assert points[-1]["date"] == today


def test_timeseries_with_tenant_filter(client):
    client.post(
        "/conversation/chat",
        json={"message": "x", "resolved": True},
        headers={"X-Tenant-ID": "t2"},
    )
    client.post(
        "/conversation/chat",
        json={"message": "y", "resolved": False},
        headers={"X-Tenant-ID": "other"},
    )
    r = client.get("/stats/timeseries", params={"tenant_id": "t2", "days": 3})
    points = r.json()["data"]
    assert len(points) == 3
    today_point = points[-1]
    assert today_point["total_conversations"] == 1
    assert today_point["successful_chats"] == 1


def test_timeseries_aggregates_when_no_tenant_filter(client):
    client.post(
        "/conversation/chat",
        json={"message": "x", "resolved": True},
        headers={"X-Tenant-ID": "t3"},
    )
    client.post(
        "/conversation/chat",
        json={"message": "y", "resolved": False},
        headers={"X-Tenant-ID": "t4"},
    )
    client.post("/feedback/csat", json={"score": 4}, headers={"X-Tenant-ID": "t3"})
    client.post("/feedback/csat", json={"score": 2}, headers={"X-Tenant-ID": "t4"})
    r = client.get("/stats/timeseries", params={"days": 1})
    point = r.json()["data"][0]
    assert point["total_conversations"] == 2
    assert point["successful_chats"] == 1
    assert point["avg_csat"] == pytest.approx(3.0)


def test_timeseries_clamps_days(client):
    low = client.get("/stats/timeseries", params={"days": 0}).json()["data"]
    high = client.get("/stats/timeseries", params={"days": 999}).json()["data"]
    assert len(low) == 1
    assert len(high) == 30


def test_v1_feedback_records_score(client):
    r = client.post("/v1/feedback", json={"tenant_id": "t5", "score": 5})
    assert r.status_code == 200
    assert tenant_stats["t5"].csat_count == 1
    assert tenant_stats["t5"].csat_sum == 5.0


def test_v1_event_chat_started_increments_counter(client):
    r = client.post(
        "/v1/event",
        json={
            "tenant_id": "t6",
            "component": "front-door",
            "action": "CHAT_STARTED",
        },
    )
    assert r.status_code == 200
    assert tenant_stats["t6"].total_conversations == 1


def test_v1_event_other_action_only_writes_audit(client):
    r = client.post(
        "/v1/event",
        json={
            "tenant_id": "t7",
            "component": "x",
            "action": "ANYTHING_ELSE",
            "metadata": {"k": "v"},
        },
    )
    assert r.status_code == 200
    assert "t7" not in tenant_stats
