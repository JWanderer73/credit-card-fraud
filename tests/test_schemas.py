"""Request-validation tests -- the 422 surface."""

from __future__ import annotations

import pytest
from pydantic import ValidationError

from app.schemas import Prediction, Transaction
from tests.conftest import requires_artifacts

pytestmark = requires_artifacts


def test_missing_field_rejected(client, fraud_payload):
    payload = dict(fraud_payload)
    del payload["V14"]
    r = client.post("/predict", json=payload)
    assert r.status_code == 422
    assert any("V14" in str(e["loc"]) for e in r.json()["detail"])


def test_wrong_type_rejected(client, fraud_payload):
    payload = dict(fraud_payload)
    payload["Amount"] = "not-a-number"
    assert client.post("/predict", json=payload).status_code == 422


def test_extra_field_rejected(client, fraud_payload):
    """extra='forbid' -- a typo'd field name must fail loudly rather than be
    silently dropped and scored against a default."""
    payload = dict(fraud_payload) | {"V29": 1.0}
    assert client.post("/predict", json=payload).status_code == 422


def test_negative_amount_rejected(client, fraud_payload):
    payload = dict(fraud_payload) | {"Amount": -1.0}
    assert client.post("/predict", json=payload).status_code == 422


def test_empty_body_rejected(client):
    assert client.post("/predict", json={}).status_code == 422


def test_integers_accepted_as_floats(feature_names):
    t = Transaction(**{name: 1 for name in feature_names})
    assert isinstance(t.Amount, float)


def test_transaction_requires_all_thirty_features(feature_names):
    partial = {name: 0.0 for name in feature_names[:-1]}
    with pytest.raises(ValidationError):
        Transaction(**partial)


def test_prediction_round_trips():
    p = Prediction(fraud_probability=0.9, is_fraud=True, threshold_used=0.87)
    assert p.model_dump() == {
        "fraud_probability": 0.9,
        "is_fraud": True,
        "threshold_used": 0.87,
    }
