"""Environment-driven settings.

Deliberately hand-rolled rather than pydantic-settings: that would be another
runtime dependency in the image for something a dozen lines of stdlib covers.

Every default is a ``default_factory``, not a plain default. A plain default
would be evaluated once, when the class body executes at import time, which
would silently freeze whatever the environment happened to look like then --
so ``get_settings()`` could never observe a later change. That distinction is
invisible until something sets an env var after import (a test, an entrypoint
script) and quietly gets the wrong config.
"""

from __future__ import annotations

import os
from dataclasses import dataclass, field
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def _path_from_env(name: str, default: Path) -> Path:
    raw = os.getenv(name)
    return Path(raw) if raw else default


def _threshold_override() -> float | None:
    raw = os.getenv("FRAUD_THRESHOLD")
    return float(raw) if raw else None

@dataclass(frozen=True)
class Settings:
    model_path: Path = field(
        default_factory=lambda: _path_from_env(
            "MODEL_PATH", ROOT / "models" / "fraud_model.onnx"
        )
    )
    metadata_path: Path = field(
        default_factory=lambda: _path_from_env(
            "METADATA_PATH", ROOT / "models" / "metadata.json"
        )
    )
    # Overrides the threshold baked into metadata.json. Unset in normal
    # operation; it exists so the precision/recall trade-off can be retuned in
    # a deployment without a retrain.
    threshold_override: float | None = field(default_factory=_threshold_override)
    # Caps batch size to bound per-request latency and memory.
    max_batch_size: int = field(
        default_factory=lambda: int(os.getenv("MAX_BATCH_SIZE", "1000"))
    )
    # Pinned to 1 on purpose: with multiple uvicorn workers, ORT's default
    # thread pool oversubscribes the cores and reduces total throughput.
    intra_op_num_threads: int = field(
        default_factory=lambda: int(os.getenv("ORT_INTRA_OP_THREADS", "1"))
    )
    # Chaos hook, off unless explicitly enabled. Makes the inference path fail
    # while leaving startup and /ready untouched -- the one failure shape no
    # amount of bad configuration can otherwise produce here, because every
    # other broken input (missing model, missing metadata, wrong feature count)
    # raises inside FraudModel.load and kills the process before it serves.
    #
    # That shape is the one worth being able to reproduce on demand: a task set
    # that passes its health check, takes production traffic, and only then
    # returns errors is what exercises the CloudWatch alarm -> CodeDeploy
    # auto-rollback chain. A task that never starts is caught by the load
    # balancer and never proves the alarms work at all.
    fault_inject_predict: bool = field(
        default_factory=lambda: os.getenv("FAULT_INJECT_PREDICT", "").lower()
        in {"1", "true", "yes"}
    )


def get_settings() -> Settings:
    return Settings()
