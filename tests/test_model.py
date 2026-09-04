"""Model-artifact tests, including the ONNX parity contract.

These run with only numpy + onnxruntime, so they exercise the committed
artifact in exactly the environment the Docker image provides.
"""

from __future__ import annotations

import numpy as np
import pytest

from app.config import Settings
from app.model import FraudModel, ModelNotLoadedError
from tests.conftest import METADATA_PATH, MODEL_PATH, requires_artifacts

pytestmark = requires_artifacts

# Mirrors src/train.py's verify_parity(). A handful of rows sit exactly on a
# split threshold, where XGBoost's float32 comparison and ONNX's BRANCH_LT can
# fall on opposite sides and flip a subtree. That is a boundary tie, not a
# conversion error, so the contract is asserted as a distribution plus label
# agreement rather than as a single max-delta bound.
MEDIAN_TOL = 1e-6
BOUNDARY_DELTA = 1e-4
MAX_BOUNDARY_FRACTION = 0.02


@pytest.fixture(scope="module")
def loaded_model() -> FraudModel:
    m = FraudModel()
    m.load(Settings(model_path=MODEL_PATH, metadata_path=METADATA_PATH))
    return m


def test_model_loads(loaded_model):
    assert loaded_model.is_loaded
    assert len(loaded_model.feature_names) == 30
    assert 0.0 < loaded_model.threshold < 1.0


def test_feature_order_matches_metadata(loaded_model, metadata):
    assert loaded_model.feature_names == metadata["features"]["names"]
    assert loaded_model.feature_names[0] == "Time"
    assert loaded_model.feature_names[-1] == "Amount"
    assert loaded_model.feature_names[1:29] == [f"V{i}" for i in range(1, 29)]


def test_predict_before_load_raises():
    with pytest.raises(ModelNotLoadedError):
        FraudModel().predict_proba(np.zeros((1, 30), dtype=np.float32))


def test_onnx_matches_sklearn_reference(loaded_model, parity_fixture):
    """The contract: the serialized model IS the model that was trained."""
    rows = np.array(parity_fixture["rows"], dtype=np.float32)
    expected = np.array(parity_fixture["sklearn_fraud_probability"], dtype=np.float64)

    actual = loaded_model.predict_proba(rows).astype(np.float64)
    delta = np.abs(actual - expected)

    assert np.median(delta) < MEDIAN_TOL, (
        f"median delta {np.median(delta):.3e} -- the whole distribution has "
        "shifted, which points at an onnxmltools/xgboost version mismatch"
    )
    boundary_fraction = float((delta > BOUNDARY_DELTA).mean())
    assert boundary_fraction <= MAX_BOUNDARY_FRACTION, (
        f"{boundary_fraction:.1%} of rows exceed {BOUNDARY_DELTA:.0e}"
    )


def test_onnx_labels_match_sklearn_at_threshold(loaded_model, parity_fixture):
    """No row may be labelled differently by the two runtimes.

    This is the only parity difference that can reach an API caller, so it is
    asserted exactly -- zero tolerance.
    """
    rows = np.array(parity_fixture["rows"], dtype=np.float32)
    expected = np.array(parity_fixture["sklearn_fraud_probability"], dtype=np.float64)
    thr = parity_fixture["threshold"]

    actual = loaded_model.predict_proba(rows).astype(np.float64)
    assert np.array_equal(actual >= thr, expected >= thr)


def test_probabilities_are_valid(loaded_model, parity_fixture):
    probs = loaded_model.predict_proba(
        np.array(parity_fixture["rows"], dtype=np.float32)
    )
    assert probs.shape == (len(parity_fixture["rows"]),)
    assert np.all((probs >= 0.0) & (probs <= 1.0))


def test_model_separates_fraud_from_normal(loaded_model, parity_fixture):
    """Sanity check that the artifact ranks, rather than merely returning numbers."""
    probs = loaded_model.predict_proba(
        np.array(parity_fixture["rows"], dtype=np.float32)
    )
    labels = np.array(parity_fixture["labels"])
    assert probs[labels == 1].mean() > probs[labels == 0].mean()


def test_build_input_respects_metadata_order(loaded_model, parity_fixture):
    """A shuffled dict must still produce the model's feature order.

    Silently accepting caller ordering would still yield a plausible-looking
    probability, which makes it the worst failure mode in the service.
    """
    names = loaded_model.feature_names
    row = parity_fixture["rows"][0]
    shuffled = dict(reversed(list(zip(names, row))))

    built = loaded_model.build_input([shuffled])
    assert built.dtype == np.float32
    np.testing.assert_allclose(built[0], np.array(row, dtype=np.float32))


def test_batch_matches_individual_predictions(loaded_model, parity_fixture):
    """Batching must not change any individual result."""
    rows = np.array(parity_fixture["rows"][:20], dtype=np.float32)
    batched = loaded_model.predict_proba(rows)
    one_at_a_time = np.concatenate(
        [loaded_model.predict_proba(rows[i : i + 1]) for i in range(len(rows))]
    )
    np.testing.assert_allclose(batched, one_at_a_time, rtol=0, atol=0)


def test_threshold_override_from_env(monkeypatch):
    """FRAUD_THRESHOLD must be read when Settings is constructed, not frozen
    at import time -- otherwise env-driven config silently does nothing."""
    monkeypatch.setenv("FRAUD_THRESHOLD", "0.25")
    monkeypatch.setenv("MODEL_PATH", str(MODEL_PATH))
    monkeypatch.setenv("METADATA_PATH", str(METADATA_PATH))

    settings = Settings()
    assert settings.threshold_override == 0.25

    m = FraudModel()
    m.load(settings)
    assert m.threshold == 0.25


def test_threshold_defaults_to_metadata_when_env_unset(monkeypatch, metadata):
    monkeypatch.delenv("FRAUD_THRESHOLD", raising=False)
    m = FraudModel()
    m.load(Settings(model_path=MODEL_PATH, metadata_path=METADATA_PATH))
    assert m.threshold == pytest.approx(metadata["threshold"]["value"])
