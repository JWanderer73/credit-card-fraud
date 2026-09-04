"""Metrics report for the exported ONNX model on the untouched holdout set.

Deliberately evaluates the ONNX artifact rather than the in-memory sklearn
pipeline: that is the thing that actually ships, and it is what the API serves.
Re-derives the same stratified split as train.py from the same random_state, so
the "holdout" here is the same holdout -- it is not re-drawn.

Usage:
    python src/evaluate.py                    # report at the tuned threshold
    python src/evaluate.py --sweep            # precision/recall across thresholds
"""

from __future__ import annotations

import argparse
import json

import numpy as np
import onnxruntime as ort
import pandas as pd
from sklearn.metrics import (
    average_precision_score,
    classification_report,
    confusion_matrix,
    precision_recall_curve,
    roc_auc_score,
)
from sklearn.model_selection import train_test_split

from train import (
    DATA_PATH,
    FEATURE_NAMES,
    METADATA_PATH,
    ONNX_PATH,
    RANDOM_STATE,
    TARGET,
    TEST_SIZE,
    log,
)


def load_holdout() -> tuple[np.ndarray, np.ndarray]:
    if not DATA_PATH.exists():
        raise SystemExit(f"Missing {DATA_PATH}. Run: unzip archive.zip -d data/")
    df = pd.read_csv(DATA_PATH)
    df[TARGET] = df[TARGET].astype(str).str.strip('"').astype(int)
    X = df[FEATURE_NAMES].to_numpy(dtype=np.float64)
    y = df[TARGET].to_numpy(dtype=np.int64)
    _, X_test, _, y_test = train_test_split(
        X, y, test_size=TEST_SIZE, stratify=y, random_state=RANDOM_STATE
    )
    return X_test, y_test


def score(X: np.ndarray) -> np.ndarray:
    sess = ort.InferenceSession(str(ONNX_PATH), providers=["CPUExecutionProvider"])
    name = sess.get_inputs()[0].name
    return sess.run(None, {name: X.astype(np.float32)})[1][:, 1].astype(np.float64)


def report(y_true: np.ndarray, y_prob: np.ndarray, threshold: float) -> dict:
    y_pred = (y_prob >= threshold).astype(int)
    tn, fp, fn, tp = confusion_matrix(y_true, y_pred).ravel()
    metrics = {
        "pr_auc": float(average_precision_score(y_true, y_prob)),
        "roc_auc": float(roc_auc_score(y_true, y_prob)),
        "threshold": threshold,
        "confusion_matrix": {"tn": int(tn), "fp": int(fp), "fn": int(fn), "tp": int(tp)},
    }

    print("\n" + "=" * 66)
    print(f"HOLDOUT EVALUATION  ({len(y_true):,} rows, {int(y_true.sum())} fraud)")
    print("=" * 66)
    print(f"PR-AUC (average precision) : {metrics['pr_auc']:.4f}   <- the metric "
          "that matters at 0.17% positives")
    print(f"ROC-AUC                    : {metrics['roc_auc']:.4f}   <- flattering "
          "and near-useless here; shown for completeness")
    print(f"\nAt threshold {threshold:.6f}:")
    print(classification_report(
        y_true, y_pred, target_names=["legit", "fraud"], digits=4, zero_division=0
    ))
    print("Confusion matrix:")
    print(f"           predicted legit   predicted fraud")
    print(f"  legit    {tn:>15,}   {fp:>15,}")
    print(f"  fraud    {fn:>15,}   {tp:>15,}")
    print(f"\n  {tp} of {tp + fn} frauds caught; {fp} false alarms out of "
          f"{tn + fp:,} legitimate transactions "
          f"({fp / max(tn + fp, 1) * 100:.4f}%).")
    return metrics


def sweep(y_true: np.ndarray, y_prob: np.ndarray, tuned: float) -> None:
    """Show what the threshold choice actually buys, since at this class
    balance the threshold is most of the model's real-world behaviour."""
    precision, recall, thresholds = precision_recall_curve(y_true, y_prob)
    precision, recall = precision[:-1], recall[:-1]
    print("\n" + "=" * 66)
    print("THRESHOLD SWEEP")
    print("=" * 66)
    print(f"{'threshold':>12} {'precision':>10} {'recall':>8} {'f1':>8} "
          f"{'false alarms':>14}")
    n_neg = int((y_true == 0).sum())
    for target in [0.05, 0.1, 0.25, 0.5, 0.75, 0.9, 0.95, 0.99]:
        i = int(np.argmin(np.abs(thresholds - target)))
        p, r = precision[i], recall[i]
        f1 = 2 * p * r / (p + r) if (p + r) > 0 else 0.0
        fp = int(round(r * y_true.sum() * (1 - p) / max(p, 1e-9)))
        print(f"{thresholds[i]:>12.6f} {p:>10.4f} {r:>8.4f} {f1:>8.4f} "
              f"{fp:>14,} / {n_neg:,}")
    i = int(np.argmin(np.abs(thresholds - tuned)))
    p, r = precision[i], recall[i]
    f1 = 2 * p * r / (p + r) if (p + r) > 0 else 0.0
    print(f"\n  tuned threshold {tuned:.6f}: precision={p:.4f} recall={r:.4f} "
          f"f1={f1:.4f}")


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--threshold", type=float, default=None,
                    help="override the threshold from metadata.json")
    ap.add_argument("--sweep", action="store_true",
                    help="also print a precision/recall threshold sweep")
    args = ap.parse_args()

    if not ONNX_PATH.exists() or not METADATA_PATH.exists():
        raise SystemExit("Missing model artifacts. Run: python src/train.py")

    metadata = json.loads(METADATA_PATH.read_text())
    threshold = args.threshold or float(metadata["threshold"]["value"])

    X_test, y_test = load_holdout()
    log(f"Scoring {X_test.shape[0]:,} holdout rows through {ONNX_PATH.name}")
    y_prob = score(X_test)

    metrics = report(y_test, y_prob, threshold)
    if args.sweep:
        sweep(y_test, y_prob, threshold)

    # The ONNX artifact should reproduce what training recorded. A drift here
    # means the committed model and the committed metrics disagree.
    recorded = metadata.get("holdout_test", {}).get("pr_auc")
    if recorded is not None and args.threshold is None:
        drift = abs(metrics["pr_auc"] - recorded)
        status = "OK" if drift < 1e-3 else "DRIFT"
        print(f"\n[{status}] metadata.json records PR-AUC {recorded:.4f}; "
              f"ONNX artifact scores {metrics['pr_auc']:.4f} (delta {drift:.2e})")


if __name__ == "__main__":
    main()
