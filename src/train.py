"""Train an XGBoost fraud classifier and export it to ONNX.

Pipeline of work:
  1. Stratified 20% holdout test set, touched exactly once at the end.
  2. Early-stopping probe to fix n_estimators (kept out of the CV loop so the
     held-out fold never leaks into the stopping decision).
  3. RandomizedSearchCV over XGBoost params, scored on average_precision
     under StratifiedKFold(5).
  4. Out-of-fold predictions from the best config, pooled across all 5 folds.
  5. Decision threshold tuned on those pooled OOF predictions (max F1).
  6. Refit on the full 80%, evaluate once on the untouched test set.
  7. Export to ONNX and verify parity against the sklearn pipeline.
"""

from __future__ import annotations

import argparse
import json
import time
from contextlib import contextmanager
from datetime import datetime, timezone
from pathlib import Path

import numpy as np
import onnx
import onnxruntime as ort
import pandas as pd
import sklearn
import xgboost
from onnxmltools.convert.xgboost.operator_converters.XGBoost import convert_xgboost
from scipy.stats import loguniform, randint, uniform
from skl2onnx import __max_supported_opset__, convert_sklearn, update_registered_converter
from skl2onnx.common._container import ModelComponentContainer
from skl2onnx.common.data_types import FloatTensorType
from skl2onnx.common.shape_calculator import calculate_linear_classifier_output_shapes
from sklearn.compose import ColumnTransformer
from sklearn.metrics import (
    average_precision_score,
    confusion_matrix,
    precision_recall_curve,
    precision_score,
    recall_score,
    roc_auc_score,
)
from sklearn.model_selection import (
    RandomizedSearchCV,
    StratifiedKFold,
    cross_val_predict,
    train_test_split,
)
from sklearn.pipeline import Pipeline
from sklearn.preprocessing import StandardScaler
from xgboost import XGBClassifier

ROOT = Path(__file__).resolve().parent.parent
DATA_PATH = ROOT / "data" / "creditcard.csv"
MODEL_DIR = ROOT / "models"
ONNX_PATH = MODEL_DIR / "fraud_model.onnx"
METADATA_PATH = MODEL_DIR / "metadata.json"
PARITY_FIXTURE_PATH = MODEL_DIR / "parity_fixture.json"

RANDOM_STATE = 42
N_SPLITS = 5
TEST_SIZE = 0.20

# Raw CSV column order. This is the contract the API serialises against, and
# the input order the ONNX graph expects. Scaling happens inside the graph.
FEATURE_NAMES = (
    ["Time"] + [f"V{i}" for i in range(1, 29)] + ["Amount"]
)
TARGET = "Class"
# Indices of the columns that need scaling; V1-V28 are already PCA outputs.
SCALE_IDX = [0, 29]


def log(msg: str) -> None:
    print(f"[{time.strftime('%H:%M:%S')}] {msg}", flush=True)


def load_data() -> tuple[np.ndarray, np.ndarray]:
    if not DATA_PATH.exists():
        raise SystemExit(
            f"Missing {DATA_PATH}. Run: unzip archive.zip -d data/"
        )
    df = pd.read_csv(DATA_PATH)
    df[TARGET] = df[TARGET].astype(str).str.strip('"').astype(int)
    X = df[FEATURE_NAMES].to_numpy(dtype=np.float64)
    y = df[TARGET].to_numpy(dtype=np.int64)
    log(f"Loaded {X.shape[0]:,} rows x {X.shape[1]} features")
    log(f"Class balance: {(y == 0).sum():,} legit / {(y == 1).sum():,} fraud "
        f"({y.mean() * 100:.3f}% positive)")
    return X, y


def build_pipeline(**clf_params) -> Pipeline:
    """Scaler lives INSIDE the pipeline so CV refits it per fold (no leakage)."""
    pre = ColumnTransformer(
        transformers=[("scale", StandardScaler(), SCALE_IDX)],
        remainder="passthrough",
    )
    defaults = dict(
        tree_method="hist",
        eval_metric="aucpr",
        random_state=RANDOM_STATE,
        n_jobs=-1,
    )
    defaults.update(clf_params)
    return Pipeline([("pre", pre), ("clf", XGBClassifier(**defaults))])


def probe_n_estimators(X: np.ndarray, y: np.ndarray, pos_weight: float) -> int:
    """One early-stopping run to fix n_estimators for the CV loop.

    Early stopping inside CV would contaminate the held-out fold's OOF
    predictions, so we resolve the tree count once, up front, on a split that
    is discarded afterwards.
    """
    X_tr, X_es, y_tr, y_es = train_test_split(
        X, y, test_size=0.2, stratify=y, random_state=RANDOM_STATE
    )
    pre = ColumnTransformer(
        transformers=[("scale", StandardScaler(), SCALE_IDX)],
        remainder="passthrough",
    )
    X_tr_t = pre.fit_transform(X_tr)
    X_es_t = pre.transform(X_es)

    clf = XGBClassifier(
        n_estimators=2000,
        learning_rate=0.1,
        max_depth=4,
        scale_pos_weight=pos_weight,
        tree_method="hist",
        eval_metric="aucpr",
        early_stopping_rounds=50,
        random_state=RANDOM_STATE,
        n_jobs=-1,
    )
    clf.fit(X_tr_t, y_tr, eval_set=[(X_es_t, y_es)], verbose=False)
    best = int(clf.best_iteration) + 1
    log(f"Early-stopping probe: best_iteration={clf.best_iteration} "
        f"-> n_estimators={best}")
    return best


def search_hyperparams(
    X: np.ndarray, y: np.ndarray, n_estimators: int, n_iter: int, pos_weight: float
) -> RandomizedSearchCV:
    """Randomized search scored on average_precision under StratifiedKFold(5).

    PR-AUC is the right target at 0.17% positives: ROC-AUC is uninformative
    here because every model clears ~0.97. It is also threshold-free, so
    scale_pos_weight can sit in the search space and be judged on fit rather
    than on where a cutoff happens to land.
    """
    param_dist = {
        "clf__max_depth": randint(3, 9),
        "clf__learning_rate": loguniform(0.02, 0.3),
        "clf__subsample": uniform(0.6, 0.4),
        "clf__colsample_bytree": uniform(0.6, 0.4),
        "clf__min_child_weight": randint(1, 11),
        "clf__gamma": uniform(0.0, 5.0),
        "clf__reg_lambda": loguniform(0.1, 10.0),
        # XGBoost docs recommend a nonzero max_delta_step for logistic
        # objectives on extremely imbalanced data; 0 keeps it disabled.
        "clf__max_delta_step": randint(0, 11),
        "clf__scale_pos_weight": [1.0, float(np.sqrt(pos_weight)), pos_weight],
    }
    cv = StratifiedKFold(n_splits=N_SPLITS, shuffle=True, random_state=RANDOM_STATE)
    search = RandomizedSearchCV(
        estimator=build_pipeline(n_estimators=n_estimators),
        param_distributions=param_dist,
        n_iter=n_iter,
        scoring="average_precision",
        cv=cv,
        random_state=RANDOM_STATE,
        n_jobs=1,       # XGBoost itself is already using all cores
        verbose=1,
        refit=False,    # we refit explicitly after threshold tuning
        return_train_score=False,
    )
    log(f"Randomized search: {n_iter} candidates x {N_SPLITS} folds "
        f"= {n_iter * N_SPLITS} fits")
    search.fit(X, y)
    log(f"Best CV average_precision: {search.best_score_:.4f}")
    return search


def tune_threshold(y_true: np.ndarray, y_prob: np.ndarray) -> tuple[float, dict]:
    """Pick the threshold maximising F1 on pooled out-of-fold predictions.

    Pooling all 5 folds means the threshold is chosen against all 492 fraud
    cases rather than the ~98 a single validation split would offer.
    """
    precision, recall, thresholds = precision_recall_curve(y_true, y_prob)
    # precision_recall_curve returns one more point than thresholds
    precision, recall = precision[:-1], recall[:-1]
    denom = precision + recall
    f1 = np.divide(2 * precision * recall, denom, out=np.zeros_like(denom),
                   where=denom > 0)
    best = int(np.argmax(f1))
    return float(thresholds[best]), {
        "f1": float(f1[best]),
        "precision": float(precision[best]),
        "recall": float(recall[best]),
    }


def evaluate(y_true: np.ndarray, y_prob: np.ndarray, threshold: float) -> dict:
    y_pred = (y_prob >= threshold).astype(int)
    tn, fp, fn, tp = confusion_matrix(y_true, y_pred).ravel()
    prec = precision_score(y_true, y_pred, zero_division=0)
    rec = recall_score(y_true, y_pred, zero_division=0)
    return {
        "pr_auc": float(average_precision_score(y_true, y_prob)),
        "roc_auc": float(roc_auc_score(y_true, y_prob)),
        "precision": float(prec),
        "recall": float(rec),
        "f1": float(2 * prec * rec / (prec + rec)) if (prec + rec) > 0 else 0.0,
        "confusion_matrix": {"tn": int(tn), "fp": int(fp), "fn": int(fn), "tp": int(tp)},
    }


@contextmanager
def _bool_attrs_as_ints():
    """Work around an onnxmltools 1.13.0 / onnx 1.17.0 incompatibility.

    onnxmltools' XGBoost converter fills ``nodes_missing_value_tracks_true``
    with Python ``bool`` values, but that is an INTS attribute in the
    ai.onnx.ml spec. Up to onnx 1.16 ``make_attribute`` accepted bools there
    (bool subclasses int); 1.17 tightened the check and now raises
    ``TypeError: Expected an int, got a boolean``.

    This is exactly the converter-lag risk the pinned xgboost 2.1.3 was chosen
    to limit, surfacing on the onnx side instead. Coercing the bools to ints as
    the attributes pass into the container is semantically a no-op -- True/False
    are the 1/0 the spec asks for -- and it keeps onnx at the version
    onnxruntime 1.20.1 depends on. The parity check in verify_parity() is what
    proves the resulting graph still computes what we trained.
    """
    original = ModelComponentContainer.add_node

    def patched(self, *args, **kwargs):
        kwargs = {
            key: ([int(v) for v in value]
                  if isinstance(value, list)
                  and any(isinstance(v, bool) for v in value)
                  else value)
            for key, value in kwargs.items()
        }
        return original(self, *args, **kwargs)

    ModelComponentContainer.add_node = patched
    try:
        yield
    finally:
        ModelComponentContainer.add_node = original


def export_onnx(pipeline: Pipeline, n_features: int) -> None:
    """Convert the fitted pipeline to ONNX.

    XGBoost is not natively known to skl2onnx, so the onnxmltools converter is
    registered first. zipmap=False yields a plain probability tensor instead of
    a list-of-dicts, which is both faster and far simpler to handle in the API.
    """
    update_registered_converter(
        XGBClassifier,
        "XGBoostXGBClassifier",
        calculate_linear_classifier_output_shapes,
        convert_xgboost,
        options={"nocl": [True, False], "zipmap": [True, False, "columns"]},
    )
    with _bool_attrs_as_ints():
        onx = convert_sklearn(
            pipeline,
            initial_types=[("input", FloatTensorType([None, n_features]))],
            options={id(pipeline): {"zipmap": False}},
            # Pinned, not left to default. onnx 1.17 advertises ai.onnx.ml
            # opset 5, but skl2onnx 1.18 only implements 3 and refuses to
            # convert otherwise; the default ai.onnx opset (22) is likewise
            # ahead of what skl2onnx has been tested against.
            target_opset={"": __max_supported_opset__, "ai.onnx.ml": 3},
        )
    MODEL_DIR.mkdir(parents=True, exist_ok=True)
    ONNX_PATH.write_bytes(onx.SerializeToString())
    onnx.checker.check_model(onnx.load(str(ONNX_PATH)))
    log(f"Wrote {ONNX_PATH} ({ONNX_PATH.stat().st_size / 1e6:.2f} MB)")


# Parity tolerances. See verify_parity() for why these are shaped this way
# rather than as a single max-delta bound.
PARITY_P99_TOL = 1e-5
PARITY_BOUNDARY_FRAC_TOL = 0.005


def verify_parity(pipeline: Pipeline, X_sample: np.ndarray, threshold: float) -> dict:
    """The contract test: the serialized model must BE the model we trained.

    Not a plain ``max|delta| < atol`` assert, and deliberately so. XGBoost
    compares against split thresholds in float32 while ONNX's TreeEnsemble
    BRANCH_LT applies its own comparison, so a row whose feature sits *exactly*
    on a split value can fall to opposite sides in the two runtimes. That flips
    a whole subtree and moves the probability by ~0.1 -- on ~0.07% of rows,
    measured. It is a tie at the boundary, not a conversion error: agreement
    elsewhere is ~3e-08, and feeding xgboost float32-scaled instead of
    float64-scaled input changes its output by exactly 0.0, which rules the
    scaler out as the cause.

    A max-delta bound would therefore be flaky by construction -- it passes or
    fails on whether a boundary row happens to be in the sample. So we assert
    the three things that actually make up the contract:

      1. p99 delta is tiny -- a genuine converter mismatch (wrong base_score,
         wrong opset, mangled attributes) shifts the whole distribution, and
         this catches that where a max bound would drown in tie noise.
      2. no label disagreements at the operating threshold -- the only
         difference that can reach a caller of the API.
      3. boundary rows stay rare, bounding the blast radius of (1) and (2).
    """
    sess = ort.InferenceSession(str(ONNX_PATH), providers=["CPUExecutionProvider"])
    onnx_prob = sess.run(None, {"input": X_sample.astype(np.float32)})[1][:, 1].astype(
        np.float64
    )
    sk_prob = pipeline.predict_proba(X_sample)[:, 1]

    delta = np.abs(onnx_prob - sk_prob)
    p99 = float(np.percentile(delta, 99))
    boundary = delta > 1e-4
    boundary_frac = float(boundary.mean())
    disagreements = int(((onnx_prob >= threshold) != (sk_prob >= threshold)).sum())

    stats = {
        "n_rows": int(X_sample.shape[0]),
        "median_abs_prob_delta": float(np.median(delta)),
        "p99_abs_prob_delta": p99,
        "max_abs_prob_delta": float(delta.max()),
        "n_boundary_rows": int(boundary.sum()),
        "boundary_row_fraction": boundary_frac,
        "label_disagreements_at_threshold": disagreements,
        "tolerances": {
            "p99": PARITY_P99_TOL,
            "boundary_fraction": PARITY_BOUNDARY_FRAC_TOL,
            "label_disagreements": 0,
        },
        "note": (
            "Non-zero max delta comes from rows sitting exactly on a split "
            "threshold, where float32 comparison differs between runtimes. "
            "Not a conversion error; see verify_parity()."
        ),
    }

    log(f"ONNX vs sklearn on {stats['n_rows']:,} rows: "
        f"median={stats['median_abs_prob_delta']:.2e} p99={p99:.2e} "
        f"max={stats['max_abs_prob_delta']:.2e}")
    log(f"  boundary rows (delta>1e-4): {stats['n_boundary_rows']} "
        f"({boundary_frac * 100:.3f}%) | "
        f"label disagreements at threshold: {disagreements}")

    failures = []
    if p99 > PARITY_P99_TOL:
        failures.append(
            f"p99 delta {p99:.3e} > {PARITY_P99_TOL:.0e} -- the whole "
            "distribution has shifted, which points at an onnxmltools/xgboost "
            "version mismatch rather than boundary ties"
        )
    if disagreements > 0:
        failures.append(
            f"{disagreements} row(s) get a different label at threshold "
            f"{threshold:.6f} -- the serialized model would serve differently"
        )
    if boundary_frac > PARITY_BOUNDARY_FRAC_TOL:
        failures.append(
            f"boundary rows {boundary_frac * 100:.3f}% > "
            f"{PARITY_BOUNDARY_FRAC_TOL * 100:.3f}%"
        )
    if failures:
        raise SystemExit("ONNX parity check FAILED:\n  - " + "\n  - ".join(failures))
    return stats


def write_parity_fixture(
    pipeline: Pipeline,
    X_test: np.ndarray,
    y_test: np.ndarray,
    threshold: float,
    n_normal: int = 150,
) -> None:
    """Persist a small, committed sample of rows with their sklearn probabilities.

    The test suite must run in CI, where the 150MB CSV does not exist and
    neither scikit-learn nor xgboost is installed. Recording sklearn's own
    outputs here lets tests assert that the *committed ONNX artifact* still
    reproduces what the training run produced, using nothing but numpy and ORT.

    This does not replace the full parity check -- verify_parity() already runs
    live against every holdout row. It is the portable half of the same
    contract, and the half that guards the artifact after it is committed.
    """
    rng = np.random.default_rng(RANDOM_STATE)
    fraud_idx = np.flatnonzero(y_test == 1)
    normal_pool = np.flatnonzero(y_test == 0)
    normal_idx = rng.choice(normal_pool, size=min(n_normal, normal_pool.size),
                            replace=False)
    idx = np.concatenate([fraud_idx, normal_idx])

    rows = X_test[idx]
    sk_prob = pipeline.predict_proba(rows)[:, 1]

    fixture = {
        "note": (
            "Rows from the untouched holdout set with the probabilities the "
            "trained sklearn pipeline produced for them. Used by the test "
            "suite to verify the committed ONNX artifact without needing the "
            "dataset or the training stack."
        ),
        "feature_names": FEATURE_NAMES,
        "threshold": threshold,
        "n_fraud": int(len(fraud_idx)),
        "n_normal": int(len(normal_idx)),
        "rows": [[float(v) for v in row] for row in rows],
        "sklearn_fraud_probability": [float(p) for p in sk_prob],
        "labels": [int(v) for v in y_test[idx]],
    }
    PARITY_FIXTURE_PATH.write_text(json.dumps(fixture, indent=2) + "\n")
    log(f"Wrote {PARITY_FIXTURE_PATH} "
        f"({len(idx)} rows: {len(fraud_idx)} fraud / {len(normal_idx)} normal)")


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--n-iter", type=int, default=30,
                    help="randomized search candidates (default 30)")
    ap.add_argument("--skip-search", action="store_true",
                    help="use hand-picked defaults instead of searching")
    args = ap.parse_args()

    started = time.time()
    X, y = load_data()

    # --- Holdout: touched exactly once, at the very end -------------------
    X_dev, X_test, y_dev, y_test = train_test_split(
        X, y, test_size=TEST_SIZE, stratify=y, random_state=RANDOM_STATE
    )
    log(f"Dev set: {X_dev.shape[0]:,} rows ({int(y_dev.sum())} fraud) | "
        f"Holdout test: {X_test.shape[0]:,} rows ({int(y_test.sum())} fraud)")

    pos_weight = float((y_dev == 0).sum() / (y_dev == 1).sum())
    log(f"Imbalance ratio (neg/pos) on dev: {pos_weight:.1f}")

    n_estimators = probe_n_estimators(X_dev, y_dev, pos_weight)

    # --- Hyperparameter search -------------------------------------------
    if args.skip_search:
        best_params = {
            "clf__max_depth": 4,
            "clf__learning_rate": 0.1,
            "clf__subsample": 0.8,
            "clf__colsample_bytree": 0.8,
            "clf__min_child_weight": 1,
            "clf__gamma": 0.0,
            "clf__reg_lambda": 1.0,
            "clf__max_delta_step": 1,
            "clf__scale_pos_weight": pos_weight,
        }
        search_summary = {"strategy": "hand-picked defaults", "n_candidates": 0}
        log("Skipping search; using hand-picked defaults")
    else:
        search = search_hyperparams(X_dev, y_dev, n_estimators, args.n_iter, pos_weight)
        best_params = search.best_params_
        search_summary = {
            "strategy": "RandomizedSearchCV",
            "n_candidates": args.n_iter,
            "scoring": "average_precision",
            "best_cv_score": float(search.best_score_),
        }

    clean = {k.replace("clf__", ""): v for k, v in best_params.items()}
    clean = {k: (float(v) if isinstance(v, (np.floating, float)) else
                 int(v) if isinstance(v, (np.integer, int)) else v)
             for k, v in clean.items()}
    log(f"Selected params: {json.dumps(clean, indent=2)}")

    # --- Out-of-fold predictions from the winning config ------------------
    cv = StratifiedKFold(n_splits=N_SPLITS, shuffle=True, random_state=RANDOM_STATE)
    best_pipeline = build_pipeline(n_estimators=n_estimators, **clean)
    log("Computing out-of-fold predictions...")
    oof_prob = cross_val_predict(
        best_pipeline, X_dev, y_dev, cv=cv, method="predict_proba", n_jobs=1
    )[:, 1]

    # Per-fold PR-AUC: the spread matters as much as the mean. A wide spread
    # means one lucky fold is carrying the average.
    fold_scores = []
    for _, val_idx in cv.split(X_dev, y_dev):
        fold_scores.append(
            float(average_precision_score(y_dev[val_idx], oof_prob[val_idx]))
        )
    log(f"Per-fold PR-AUC: {[round(s, 4) for s in fold_scores]}")
    log(f"CV PR-AUC: {np.mean(fold_scores):.4f} +/- {np.std(fold_scores):.4f}")

    # --- Threshold on pooled OOF -----------------------------------------
    threshold, oof_at_thr = tune_threshold(y_dev, oof_prob)
    log(f"Tuned threshold (max F1 on pooled OOF): {threshold:.6f}")
    log(f"  OOF precision={oof_at_thr['precision']:.4f} "
        f"recall={oof_at_thr['recall']:.4f} f1={oof_at_thr['f1']:.4f}")

    # --- Final refit + single honest evaluation ---------------------------
    log("Refitting on full dev set...")
    best_pipeline.fit(X_dev, y_dev)
    test_prob = best_pipeline.predict_proba(X_test)[:, 1]
    test_metrics = evaluate(y_test, test_prob, threshold)
    log(f"HOLDOUT TEST: PR-AUC={test_metrics['pr_auc']:.4f} "
        f"precision={test_metrics['precision']:.4f} "
        f"recall={test_metrics['recall']:.4f} f1={test_metrics['f1']:.4f}")
    log(f"  confusion: {test_metrics['confusion_matrix']}")

    # --- Export + parity --------------------------------------------------
    export_onnx(best_pipeline, len(FEATURE_NAMES))
    # Parity is checked on the whole holdout set, not a 1000-row slice:
    # boundary rows are rare enough that a small sample would miss them and
    # report a falsely clean result.
    parity = verify_parity(best_pipeline, X_test, threshold)
    write_parity_fixture(best_pipeline, X_test, y_test, threshold)

    metadata = {
        "model": {
            "framework": "xgboost",
            "format": "onnx",
            "onnx_file": ONNX_PATH.name,
            "n_estimators": n_estimators,
            "hyperparameters": clean,
        },
        "features": {
            "names": FEATURE_NAMES,
            "n_features": len(FEATURE_NAMES),
            "scaled_indices": SCALE_IDX,
            "note": "Input order is the raw CSV order; scaling is inside the graph.",
        },
        "threshold": {
            "value": threshold,
            "policy": "max_f1_on_pooled_oof",
            "oof_precision": oof_at_thr["precision"],
            "oof_recall": oof_at_thr["recall"],
            "oof_f1": oof_at_thr["f1"],
        },
        "validation": {
            "strategy": f"StratifiedKFold(n_splits={N_SPLITS}, shuffle=True)",
            "search": search_summary,
            "fold_pr_auc": fold_scores,
            "cv_pr_auc_mean": float(np.mean(fold_scores)),
            "cv_pr_auc_std": float(np.std(fold_scores)),
            "oof_pr_auc": float(average_precision_score(y_dev, oof_prob)),
        },
        "holdout_test": {
            "note": "Untouched during selection; these are the reportable numbers.",
            "test_size": TEST_SIZE,
            "n_rows": int(X_test.shape[0]),
            "n_fraud": int(y_test.sum()),
            **test_metrics,
        },
        "onnx_parity": parity,
        "provenance": {
            "trained_at": datetime.now(timezone.utc).isoformat(),
            "random_state": RANDOM_STATE,
            "train_duration_sec": round(time.time() - started, 1),
            "versions": {
                "numpy": np.__version__,
                "scikit_learn": sklearn.__version__,
                "xgboost": xgboost.__version__,
                "onnx": onnx.__version__,
                "onnxruntime": ort.__version__,
            },
        },
    }
    METADATA_PATH.write_text(json.dumps(metadata, indent=2) + "\n")
    log(f"Wrote {METADATA_PATH}")
    log(f"Done in {time.time() - started:.1f}s")


if __name__ == "__main__":
    main()
