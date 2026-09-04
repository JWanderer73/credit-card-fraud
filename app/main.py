"""FastAPI application: real-time fraud inference over ONNX Runtime."""

from __future__ import annotations

import logging
from contextlib import asynccontextmanager

from fastapi import FastAPI, HTTPException, Request, status
from fastapi.responses import JSONResponse

from app.config import get_settings
from app.model import ModelNotLoadedError, model
from app.schemas import (
    BatchRequest,
    BatchResponse,
    HealthResponse,
    Prediction,
    ReadyResponse,
    Transaction,
)

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
logger = logging.getLogger(__name__)

settings = get_settings()


@asynccontextmanager
async def lifespan(app: FastAPI):
    """Load the ORT session once per process, not once per request.

    A failure here is left to propagate: a process that cannot serve should
    not come up and pass its health check.
    """
    model.load(settings)
    yield
    model.unload()


app = FastAPI(
    title="Credit Card Fraud Detection API",
    description=(
        "Real-time fraud scoring for credit-card transactions, served from an "
        "XGBoost model exported to ONNX. The decision threshold is tuned on "
        "pooled out-of-fold predictions rather than left at 0.5."
    ),
    version="1.0.0",
    lifespan=lifespan,
)


def _predict(records: list[dict]) -> list[Prediction]:
    features = model.build_input(records)
    probabilities = model.predict_proba(features)
    threshold = model.threshold
    return [
        Prediction(
            fraud_probability=float(p),
            is_fraud=bool(p >= threshold),
            threshold_used=threshold,
        )
        for p in probabilities
    ]


@app.exception_handler(ModelNotLoadedError)
async def model_not_loaded_handler(request: Request, exc: ModelNotLoadedError):
    return JSONResponse(
        status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
        content={"detail": "Model is not loaded."},
    )


@app.get("/health", response_model=HealthResponse, tags=["ops"])
async def health() -> HealthResponse:
    """Liveness. Deliberately does not touch the model -- it answers whether
    the process is up, not whether it is ready to serve."""
    return HealthResponse(status="ok")


@app.get("/ready", response_model=ReadyResponse, tags=["ops"])
async def ready() -> ReadyResponse:
    """Readiness -- this is the ALB target-group health check.

    503 until the session is loaded, so the load balancer does not route to a
    task that would fail every request.
    """
    if not model.is_loaded:
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="Model is not loaded.",
        )
    return ReadyResponse(status="ready", model_loaded=True, threshold=model.threshold)


@app.post("/predict", response_model=Prediction, tags=["inference"])
async def predict(transaction: Transaction) -> Prediction:
    """Score a single transaction."""
    return _predict([transaction.model_dump()])[0]


@app.post("/predict/batch", response_model=BatchResponse, tags=["inference"])
async def predict_batch(payload: BatchRequest) -> BatchResponse:
    """Score many transactions in one call.

    ONNX Runtime amortises per-call overhead heavily, so this is dramatically
    faster per transaction than the same count of single calls. Capped to bound
    per-request latency and memory.
    """
    n = len(payload.transactions)
    if n > settings.max_batch_size:
        raise HTTPException(
            status_code=status.HTTP_413_REQUEST_ENTITY_TOO_LARGE,
            detail=(
                f"Batch size {n} exceeds the maximum of "
                f"{settings.max_batch_size}."
            ),
        )
    predictions = _predict([t.model_dump() for t in payload.transactions])
    return BatchResponse(predictions=predictions, count=len(predictions))


@app.get("/", include_in_schema=False)
async def root() -> dict:
    return {"service": "credit-card-fraud-api", "docs": "/docs"}
