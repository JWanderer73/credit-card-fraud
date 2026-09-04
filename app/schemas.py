"""Request/response models.

Every one of the 30 features is an explicitly named float field. That is
verbose, but it is what makes /docs self-documenting: a reviewer opening the
OpenAPI page sees the exact contract instead of an opaque list of numbers.
"""

from __future__ import annotations

from pydantic import BaseModel, ConfigDict, Field


class Transaction(BaseModel):
    """One credit-card transaction, in the ULB dataset's schema.

    V1-V28 are the anonymised PCA components published with the dataset; only
    Time and Amount are in original units. Scaling happens inside the ONNX
    graph, so values are passed through exactly as they appear in the CSV.
    """

    model_config = ConfigDict(extra="forbid")

    Time: float = Field(
        ..., description="Seconds elapsed between this transaction and the first in the dataset."
    )
    V1: float = Field(..., description="PCA component V1.")
    V2: float = Field(..., description="PCA component V2.")
    V3: float = Field(..., description="PCA component V3.")
    V4: float = Field(..., description="PCA component V4.")
    V5: float = Field(..., description="PCA component V5.")
    V6: float = Field(..., description="PCA component V6.")
    V7: float = Field(..., description="PCA component V7.")
    V8: float = Field(..., description="PCA component V8.")
    V9: float = Field(..., description="PCA component V9.")
    V10: float = Field(..., description="PCA component V10.")
    V11: float = Field(..., description="PCA component V11.")
    V12: float = Field(..., description="PCA component V12.")
    V13: float = Field(..., description="PCA component V13.")
    V14: float = Field(..., description="PCA component V14.")
    V15: float = Field(..., description="PCA component V15.")
    V16: float = Field(..., description="PCA component V16.")
    V17: float = Field(..., description="PCA component V17.")
    V18: float = Field(..., description="PCA component V18.")
    V19: float = Field(..., description="PCA component V19.")
    V20: float = Field(..., description="PCA component V20.")
    V21: float = Field(..., description="PCA component V21.")
    V22: float = Field(..., description="PCA component V22.")
    V23: float = Field(..., description="PCA component V23.")
    V24: float = Field(..., description="PCA component V24.")
    V25: float = Field(..., description="PCA component V25.")
    V26: float = Field(..., description="PCA component V26.")
    V27: float = Field(..., description="PCA component V27.")
    V28: float = Field(..., description="PCA component V28.")
    Amount: float = Field(..., ge=0.0, description="Transaction amount.")


class BatchRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")

    transactions: list[Transaction] = Field(
        ..., min_length=1, description="Transactions to score in one call."
    )


class Prediction(BaseModel):
    fraud_probability: float = Field(
        ..., description="Model score in [0, 1]. See the calibration note in the README."
    )
    is_fraud: bool = Field(..., description="fraud_probability >= threshold_used.")
    threshold_used: float = Field(
        ..., description="Decision threshold applied, tuned on out-of-fold predictions."
    )


class BatchResponse(BaseModel):
    predictions: list[Prediction]
    count: int


class HealthResponse(BaseModel):
    status: str


class ReadyResponse(BaseModel):
    status: str
    model_loaded: bool
    threshold: float | None = None
