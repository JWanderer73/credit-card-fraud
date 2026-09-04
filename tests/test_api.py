"""API-level tests via TestClient."""

from __future__ import annotations

import pytest

from tests.conftest import requires_artifacts

pytestmark = requires_artifacts


def test_health_does_not_require_model(client):
    r = client.get("/health")
    assert r.status_code == 200
    assert r.json() == {"status": "ok"}


def test_ready_reports_loaded_model(client, threshold):
    r = client.get("/ready")
    assert r.status_code == 200
    body = r.json()
    assert body["status"] == "ready"
    assert body["model_loaded"] is True
    assert body["threshold"] == pytest.approx(threshold)


def test_predict_known_fraud(client, fraud_payload, threshold):
    r = client.post("/predict", json=fraud_payload)
    assert r.status_code == 200
    body = r.json()
    assert body["fraud_probability"] >= threshold
    assert body["is_fraud"] is True
    assert body["threshold_used"] == pytest.approx(threshold)


def test_predict_known_normal(client, normal_payload, threshold):
    r = client.post("/predict", json=normal_payload)
    assert r.status_code == 200
    body = r.json()
    assert body["fraud_probability"] < threshold
    assert body["is_fraud"] is False


def test_is_fraud_is_consistent_with_threshold(client, fraud_payload, normal_payload):
    for payload in (fraud_payload, normal_payload):
        body = client.post("/predict", json=payload).json()
        assert body["is_fraud"] == (
            body["fraud_probability"] >= body["threshold_used"]
        )


def test_predict_batch(client, fraud_payload, normal_payload):
    r = client.post(
        "/predict/batch",
        json={"transactions": [fraud_payload, normal_payload, normal_payload]},
    )
    assert r.status_code == 200
    body = r.json()
    assert body["count"] == 3
    assert len(body["predictions"]) == 3
    assert body["predictions"][0]["is_fraud"] is True
    assert body["predictions"][1]["is_fraud"] is False


def test_batch_matches_single_endpoint(client, fraud_payload, normal_payload):
    """Batching is an optimisation, not a different model."""
    singles = [
        client.post("/predict", json=p).json()["fraud_probability"]
        for p in (fraud_payload, normal_payload)
    ]
    batched = [
        p["fraud_probability"]
        for p in client.post(
            "/predict/batch",
            json={"transactions": [fraud_payload, normal_payload]},
        ).json()["predictions"]
    ]
    assert singles == pytest.approx(batched)


def test_batch_preserves_input_order(client, fraud_payload, normal_payload):
    order = [normal_payload, fraud_payload, normal_payload]
    body = client.post("/predict/batch", json={"transactions": order}).json()
    assert [p["is_fraud"] for p in body["predictions"]] == [False, True, False]


def test_oversized_batch_rejected(client, normal_payload):
    from app.main import settings

    n = settings.max_batch_size + 1
    r = client.post("/predict/batch", json={"transactions": [normal_payload] * n})
    assert r.status_code == 413
    assert str(settings.max_batch_size) in r.json()["detail"]


def test_batch_at_cap_is_accepted(client, normal_payload):
    from app.main import settings

    r = client.post(
        "/predict/batch",
        json={"transactions": [normal_payload] * settings.max_batch_size},
    )
    assert r.status_code == 200
    assert r.json()["count"] == settings.max_batch_size


def test_empty_batch_rejected(client):
    r = client.post("/predict/batch", json={"transactions": []})
    assert r.status_code == 422


def test_openapi_documents_named_features(client):
    """The 30 explicit fields are the reason /docs is worth opening."""
    schema = client.get("/openapi.json").json()
    props = schema["components"]["schemas"]["Transaction"]["properties"]
    assert "Time" in props and "Amount" in props
    assert all(f"V{i}" in props for i in range(1, 29))
