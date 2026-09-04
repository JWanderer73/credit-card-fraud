"""Shared fixtures.

Everything here is sourced from committed artifacts under ``models/`` -- never
from ``data/creditcard.csv``, which is gitignored and absent in CI. That
constraint is deliberate: the test suite has to be able to verify the artifact
that actually ships, on a runner that has neither the dataset nor the training
stack installed.
"""

from __future__ import annotations

import json
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

ROOT = Path(__file__).resolve().parent.parent
MODEL_PATH = ROOT / "models" / "fraud_model.onnx"
METADATA_PATH = ROOT / "models" / "metadata.json"
FIXTURE_PATH = ROOT / "models" / "parity_fixture.json"

requires_artifacts = pytest.mark.skipif(
    not (MODEL_PATH.exists() and METADATA_PATH.exists() and FIXTURE_PATH.exists()),
    reason="Trained artifacts missing -- run `python src/train.py` first.",
)


@pytest.fixture(scope="session")
def metadata() -> dict:
    return json.loads(METADATA_PATH.read_text())


@pytest.fixture(scope="session")
def parity_fixture() -> dict:
    return json.loads(FIXTURE_PATH.read_text())


@pytest.fixture(scope="session")
def feature_names(parity_fixture) -> list[str]:
    return parity_fixture["feature_names"]


@pytest.fixture(scope="session")
def threshold(metadata) -> float:
    return float(metadata["threshold"]["value"])


def _row_to_payload(names: list[str], row: list[float]) -> dict:
    return dict(zip(names, row))


@pytest.fixture(scope="session")
def fraud_payload(parity_fixture, feature_names) -> dict:
    """A transaction the model scores as fraud, above the tuned threshold."""
    probs = parity_fixture["sklearn_fraud_probability"]
    labels = parity_fixture["labels"]
    thr = parity_fixture["threshold"]
    idx = next(
        i for i, (p, lab) in enumerate(zip(probs, labels)) if lab == 1 and p >= thr
    )
    return _row_to_payload(feature_names, parity_fixture["rows"][idx])


@pytest.fixture(scope="session")
def normal_payload(parity_fixture, feature_names) -> dict:
    """A transaction the model scores as legitimate, below the tuned threshold."""
    probs = parity_fixture["sklearn_fraud_probability"]
    labels = parity_fixture["labels"]
    thr = parity_fixture["threshold"]
    idx = next(
        i for i, (p, lab) in enumerate(zip(probs, labels)) if lab == 0 and p < thr
    )
    return _row_to_payload(feature_names, parity_fixture["rows"][idx])


@pytest.fixture(scope="session")
def client():
    """TestClient as a context manager so lifespan startup actually runs.

    Without the `with` block FastAPI never fires the lifespan handler and the
    model is never loaded -- every inference test would fail confusingly.
    """
    from app.main import app

    with TestClient(app) as c:
        yield c
