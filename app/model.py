"""ONNX Runtime session wrapper.

The training stack (xgboost, scikit-learn, pandas) is deliberately absent from
the runtime image -- ORT executes the serialized graph standalone. This module
is the only thing that knows how the graph is shaped.
"""

from __future__ import annotations

import json
import logging
from pathlib import Path

import numpy as np
import onnxruntime as ort

from app.config import Settings

logger = logging.getLogger(__name__)

PROBABILITIES_OUTPUT = "probabilities"


class ModelNotLoadedError(RuntimeError):
    """Raised if inference is attempted before the session is initialised."""


class FraudModel:
    """Holds the ORT session, the feature order, and the decision threshold.

    Constructed empty and filled by :meth:`load` from the app's lifespan
    handler, so the session is created exactly once per process rather than
    per request.
    """

    def __init__(self) -> None:
        self._session: ort.InferenceSession | None = None
        self._feature_names: list[str] = []
        self._threshold: float | None = None
        self._input_name: str = "input"
        self._prob_index: int = 1
        self._metadata: dict = {}

    @property
    def is_loaded(self) -> bool:
        return self._session is not None

    @property
    def feature_names(self) -> list[str]:
        return list(self._feature_names)

    @property
    def threshold(self) -> float:
        if self._threshold is None:
            raise ModelNotLoadedError("Model metadata has not been loaded.")
        return self._threshold

    @property
    def metadata(self) -> dict:
        return self._metadata

    def load(self, settings: Settings) -> None:
        metadata = self._read_metadata(settings.metadata_path)

        # Feature order comes from metadata, never from dict iteration order --
        # a silently reordered input would still produce a plausible-looking
        # probability, which is the worst possible failure mode here.
        self._feature_names = list(metadata["features"]["names"])
        self._threshold = (
            settings.threshold_override
            if settings.threshold_override is not None
            else float(metadata["threshold"]["value"])
        )
        self._metadata = metadata

        if not settings.model_path.exists():
            raise FileNotFoundError(f"ONNX model not found at {settings.model_path}")

        opts = ort.SessionOptions()
        # Pinned to 1 on purpose: with multiple uvicorn workers ORT's default
        # thread pool oversubscribes the cores and reduces total throughput.
        opts.intra_op_num_threads = settings.intra_op_num_threads
        opts.graph_optimization_level = ort.GraphOptimizationLevel.ORT_ENABLE_ALL

        self._session = ort.InferenceSession(
            str(settings.model_path),
            sess_options=opts,
            providers=["CPUExecutionProvider"],
        )

        inputs = self._session.get_inputs()
        self._input_name = inputs[0].name
        expected = len(self._feature_names)
        actual = inputs[0].shape[-1]
        if isinstance(actual, int) and actual != expected:
            raise ValueError(
                f"Model expects {actual} features but metadata lists {expected}."
            )

        output_names = [o.name for o in self._session.get_outputs()]
        self._prob_index = (
            output_names.index(PROBABILITIES_OUTPUT)
            if PROBABILITIES_OUTPUT in output_names
            else 1
        )

        logger.info(
            "Loaded model from %s (%d features, threshold=%.6f)",
            settings.model_path,
            expected,
            self._threshold,
        )

    def unload(self) -> None:
        self._session = None

    @staticmethod
    def _read_metadata(path: Path) -> dict:
        if not path.exists():
            raise FileNotFoundError(f"Model metadata not found at {path}")
        return json.loads(path.read_text())

    def build_input(self, records: list[dict]) -> np.ndarray:
        """Order the incoming records into the model's feature layout.

        float32 explicitly: the graph's input is a float tensor, and letting
        numpy pick float64 would force a conversion on every call.
        """
        return np.array(
            [[record[name] for name in self._feature_names] for record in records],
            dtype=np.float32,
        )

    def predict_proba(self, features: np.ndarray) -> np.ndarray:
        """Fraud probabilities (the positive class column) for each row."""
        if self._session is None:
            raise ModelNotLoadedError("Model session is not loaded.")
        if features.dtype != np.float32:
            features = features.astype(np.float32)
        outputs = self._session.run(None, {self._input_name: features})
        return outputs[self._prob_index][:, 1]


# Module-level singleton, populated by the lifespan handler.
model = FraudModel()
