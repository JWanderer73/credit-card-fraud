# Credit Card Fraud Detection — Real-Time Inference API

A FastAPI service that scores credit-card transactions for fraud in real time,
serving an XGBoost model exported to ONNX. Sustains **~4,100 single-transaction
predictions per second at a p99 of 6.7 ms** on a 2020 M1 MacBook Air.

**Status: Phase 1 complete** (model + API). Phase 2 (Docker) and Phase 3 (AWS
ECS Fargate deployment) are not built yet — see [Project status](#project-status).

---

## Results

Trained on the [ULB credit-card fraud dataset](https://www.kaggle.com/datasets/mlg-ulb/creditcardfraud):
284,807 transactions, 492 of them fraudulent (**0.173% positive**).

### Held-out test set — the reportable numbers

A stratified 20% split (56,962 rows, 98 frauds) was held out at the start and
touched exactly once, at the very end. Cross-validation guided model and
threshold selection, so those numbers are no longer unbiased; these are.

| metric | value |
|---|---|
| **PR-AUC (average precision)** | **0.8749** |
| Precision | 0.9000 |
| Recall | 0.8265 |
| F1 | 0.8617 |
| ROC-AUC | 0.9841 |

Confusion matrix at the tuned threshold (0.7565):

|  | predicted legit | predicted fraud |
|---|---|---|
| **actually legit** | 56,855 | 9 |
| **actually fraud** | 17 | 81 |

**81 of 98 frauds caught, at the cost of 9 false alarms in 56,864 legitimate
transactions (0.016%).**

### Why PR-AUC and not ROC-AUC

At 0.173% positives, ROC-AUC is misleadingly flattering — this model scores
0.984, and so does almost any model on this dataset, because the enormous true-
negative count swamps the false-positive rate. PR-AUC only involves the
positive class, so it actually discriminates between models. That is why it is
also what the hyperparameter search optimised.

### Cross-validation

Stratified 5-fold on the remaining 80%. Stratification is not optional at 492
positives — unstratified folds can differ by tens of fraud cases and make fold
metrics incomparable.

| fold | 1 | 2 | 3 | 4 | 5 | mean ± std |
|---|---|---|---|---|---|---|
| PR-AUC | 0.8537 | 0.8260 | 0.8442 | 0.9001 | 0.8515 | **0.8551 ± 0.0245** |

The spread matters as much as the mean: every fold sits within 0.045 of it, so
no single lucky fold is carrying the average.

---

## How it was built

### The scaler lives inside the pipeline

`StandardScaler` (on `Time` and `Amount` only — `V1`–`V28` are already PCA
outputs) sits inside the sklearn `Pipeline`, so cross-validation refits it on
each fold's training portion alone. Scaling before splitting would leak
test-fold statistics into every fold and silently inflate every number above.

### Threshold tuned on pooled out-of-fold predictions

At this class balance the decision threshold *is* most of the model's
real-world behaviour, so leaving it at 0.5 would waste the model. Out-of-fold
predictions from all 5 folds are concatenated into one full-length vector and
the threshold that maximises F1 is chosen on that curve. Pooling means the
threshold is chosen against all 394 dev-set frauds rather than the ~79 a single
validation split would offer, so it is far less likely to be an artifact of one
split.

`src/evaluate.py --sweep` prints the full precision/recall trade-off, since the
right operating point is a business decision, not a modelling one:

| threshold | precision | recall | false alarms |
|---|---|---|---|
| 0.099 | 0.759 | 0.867 | 27 |
| 0.419 | 0.845 | 0.837 | 15 |
| **0.756** (tuned) | **0.890** | **0.827** | **10** |
| 0.961 | 0.931 | 0.827 | 6 |

The threshold can be overridden at deploy time with `FRAUD_THRESHOLD` — no
retrain needed to move along this curve.

### ⚠️ Probabilities are ranked, not calibrated

The hyperparameter search selected `scale_pos_weight=577.3` (the full
negative/positive ratio). This is safe to search *because* PR-AUC is
threshold-free — it judges how well the model **ranks** transactions, not where
a cutoff lands — but it means the returned `fraud_probability` is deliberately
**not calibrated** and systematically overstates absolute fraud risk.

**A returned 0.7 does not mean "70% of such transactions are fraud."** Ranking
quality and PR-AUC are unaffected. If calibrated probabilities are ever needed,
wrap the classifier in `CalibratedClassifierCV` or fit an isotonic model on the
out-of-fold predictions.

### Stratified split, not temporal

A temporal split on `Time` is arguably more honest for fraud detection, since
production models predict forward in time. `Time` spans only ~2 days in this
dataset, which is too short for a temporal split to represent genuine concept
drift, so the stratified split is the defensible standard choice here. Worth
knowing the trade-off exists.

---

## The API

```bash
uvicorn app.main:app --host 0.0.0.0 --port 8000 --workers 2
```

Interactive docs at `/docs`. All 30 features are explicitly named fields, so
the OpenAPI page documents the exact contract.

| endpoint | purpose |
|---|---|
| `GET /health` | Liveness. Does not touch the model — answers whether the process is up. |
| `GET /ready` | Readiness. 503 until the ONNX session is loaded. This is the load-balancer health check. |
| `POST /predict` | Score one transaction. |
| `POST /predict/batch` | Score up to 1,000 transactions in one call. |

```bash
curl -X POST localhost:8000/predict -H 'Content-Type: application/json' \
  -d '{"Time":0,"V1":-1.36,"V2":-0.07, ..., "V28":-0.02,"Amount":149.62}'

{"fraud_probability":0.00016,"is_fraud":false,"threshold_used":0.7564894557}
```

### Design notes

- **The ONNX session is created once**, in a `lifespan` handler — not per
  request.
- **`intra_op_num_threads=1`.** With multiple uvicorn workers, ORT's default
  thread pool oversubscribes the cores and *reduces* total throughput.
- **Input is ordered from `metadata.json`**, never from dict iteration order. A
  silently reordered input would still return a plausible-looking probability,
  which is the worst available failure mode.
- **`extra="forbid"`** on the request schema, so a typo'd field name fails
  loudly instead of being dropped and scored against a default.

---

## Performance

Measured by `scripts/benchmark.py` against local uvicorn (2 workers), M1
MacBook Air, 8 cores / 8 GB, arm64:

| mode | throughput | p50 | p95 | p99 |
|---|---|---|---|---|
| **single** (1 txn/request) | **4,120 predictions/s** | 3.77 ms | 4.83 ms | 6.70 ms |
| batch (500 txns/request) | 62,544 predictions/s | 128.8 ms | 152.2 ms | 159.9 ms |

82,416 requests, zero errors. **The single-prediction figure is the honest one
to quote for "real-time"** — one transaction, one HTTP request, end to end.
Batch throughput is ~15x higher because ONNX Runtime amortises per-call
overhead across the batch; it is reported separately rather than folded into
the headline.

**Both numbers understate the server**, because the load generator shares the
same 8 cores. That also produced the one benchmarking trap worth recording: a
*single* Python client process peaks around 1,960 RPS and then gets **slower**
as concurrency rises, because it saturates its own core on JSON encoding and
asyncio bookkeeping. Reading that as the server's limit would have understated
throughput by 6x. `benchmark.py` therefore spreads load across multiple client
*processes* and pools the latency samples before computing percentiles.

---

## Reproducing

```bash
python -m venv .venv && source .venv/bin/activate
pip install -r requirements-dev.txt

unzip archive.zip -d data/           # dataset is gitignored

python src/train.py --skip-search    # ~25 s: full path, hand-picked params
python src/train.py --n-iter 150     # ~34 min: the real 750-fit search
python src/evaluate.py --sweep       # metrics for the ONNX artifact
pytest -v
```

Everything is seeded with `random_state=42` and is reproducible: refitting from
the hyperparameters recorded in `metadata.json` reproduces the exported model
to 16 significant figures.

### Dependency split

This is the highest-leverage decision in the project, and it is what will keep
the Docker image small in Phase 2:

- **`requirements.txt`** (ships in the image): `fastapi`, `uvicorn`, `pydantic`,
  `numpy`, `onnxruntime`.
- **`requirements-dev.txt`** (training and tests only): adds `pandas`,
  `scikit-learn`, `xgboost`, `skl2onnx`, `onnxmltools`, `onnx`, `pytest`,
  `httpx`.

**Neither xgboost nor scikit-learn is needed to serve.** ONNX Runtime executes
the serialized graph standalone. CI installs *only* the runtime set and asserts
the training stack is absent — if a test ever needs sklearn to pass, that test
is not exercising the artifact that actually ships.

---

## Tests

31 tests, run with **only** numpy + onnxruntime + pytest — no dataset, no
training stack. The 150 MB CSV is gitignored and never reaches CI, so the suite
verifies the *committed artifact* in the same shape the Docker image provides.

`models/parity_fixture.json` (248 holdout rows with the probabilities the
trained sklearn pipeline produced for them) is what makes that possible.

### The ONNX parity contract

The important test asserts that the serialized model **is** the model that was
trained. It is deliberately *not* a plain `max|delta| < atol` check.

XGBoost compares against split thresholds in float32 while ONNX's
`TreeEnsembleClassifier` applies its own `BRANCH_LT`, so a row whose feature
value sits *exactly* on a split value can fall to opposite sides in the two
runtimes. That flips an entire subtree and moves the probability by ~0.1. On
this model it affects 124 of 56,962 holdout rows (0.218%).

This is a tie at the boundary, not a conversion error, and it was verified as
such: agreement elsewhere is ~3e-08, every affected row has a feature within
1.1e-08 of a split threshold, and feeding XGBoost float32-scaled instead of
float64-scaled input changes its output by *exactly* 0.0 — ruling out the
scaler as the cause.

A max-delta bound would therefore be flaky by construction, passing or failing
on whether a boundary row happened to land in the sample. The contract is
asserted as three things instead:

1. **median/p99 delta is tiny** — a real converter mismatch shifts the whole
   distribution, which this catches and a max bound would drown out;
2. **zero label disagreements at the operating threshold** — the only
   difference that can actually reach an API caller (asserted exactly, on all
   56,962 rows during training);
3. **boundary rows stay rare**, bounding the blast radius of the other two.

---

## Project status

- [x] **Phase 1 — Model + FastAPI.** Training, tuning, ONNX export, API, 31
      tests, benchmark.
- [ ] **Phase 2 — Docker.** Multi-stage build, target < 400 MB.
- [ ] **Phase 3 — AWS.** Terraform, ECS Fargate across 2 AZs behind an ALB,
      target-tracking autoscaling, GitHub Actions OIDC deploy.

"Highly available" only becomes true at Phase 3 (2 AZs, ≥2 tasks); Phases 1–2
do not support that claim on their own.

## Repository layout

```
├── src/train.py            # train, tune threshold, export ONNX, verify parity
├── src/evaluate.py         # metrics report for the ONNX artifact
├── app/main.py             # FastAPI app, lifespan, routes
├── app/model.py            # ONNX Runtime session wrapper
├── app/schemas.py          # request/response models (30 named features)
├── app/config.py           # env-driven settings
├── tests/                  # 31 tests, runtime deps only
├── scripts/benchmark.py    # multi-process load generator
├── models/                 # committed: ONNX model, metadata, parity fixture
└── .github/workflows/ci.yml
```
