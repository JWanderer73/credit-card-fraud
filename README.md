# Credit Card Fraud Detection — Real-Time Inference API

A FastAPI service that scores credit-card transactions for fraud in real time,
serving an XGBoost model exported to ONNX. Sustains **~4,100 single-transaction
predictions per second at a p99 of 6.7 ms** on a 2020 M1 MacBook Air.

**Status: Phases 1–2 complete** (model + API + Docker). Phase 3 (AWS ECS
Fargate deployment) is not built yet — see [Project status](#project-status).

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

## Docker

```bash
docker build -t fraud-api .          # runtime image (default target)
docker run -p 8000:8000 fraud-api
```

Multi-stage build, non-root (`uid 10001`), `HEALTHCHECK` on `/health`, and
`WORKERS` tunable at container start without a rebuild.

### The dependency split, measured

| image | size | packages |
|---|---|---|
| **`fraud-api` (multi-stage, runtime deps)** | **382 MB** | **25** |
| naive single-stage with the training stack | 1.05 GB | 48 |

**668 MB smaller — a 64% reduction.** Nothing about the model changes; the
training stack simply never enters the image, because ONNX Runtime executes the
serialized graph on its own. Verified directly:

```console
$ docker run --rm fraud-api pip list | grep -Ei 'scikit|xgboost|pandas'
$ echo $?
1        # no matches — the training stack is not in the shipped image
```

### Dropping sympy: 74 MB, verified not assumed

`onnxruntime` depends on `sympy`, which is larger than onnxruntime itself —
about 30% of the virtualenv. It is used for *symbolic shape inference*, a
model-authoring and optimization tool, not for executing a session.

Measured by building each variant, rather than attributed by guesswork:

| build | size |
|---|---|
| multi-stage, as pip resolves it | 528 MB |
| − `sympy` + `mpmath` | 425 MB (**−103 MB**) |
| − install-time bytecode caches | **382 MB** (−43 MB) |

That is what brings it under the 400 MB target; the dependency split alone
lands at 528 MB.

That claim was checked rather than assumed. `sympy` is absent from
`sys.modules` after importing `onnxruntime`, after creating the
`InferenceSession`, **and** after running inference — and the full test suite
passes inside the image without it.

The honest trade-off: `onnxruntime` still *declares* the dependency, so
`pip check` will report the metadata as inconsistent. The `test` build stage is
what keeps that safe — if any ORT path the service actually uses ever needs
sympy, the **build** fails rather than the container failing in production.

### Testing the artifact that ships

The `test` stage derives `FROM` the runtime layers and adds only pytest and the
test files, so the interpreter, model and application code under test are
byte-for-byte those in the shipped image — and the test files never reach it.

```bash
docker build --target test .    # 31 passed; a failure fails the build
```

This exists to close a specific gap: local builds are native **arm64** for
fast iteration, but Fargate is **x86_64** and the `linux/amd64` image is only
ever built on CI's x86 runners. Testing it there is what keeps the split from
being a "works on my machine" trap. `runtime` is deliberately the **last**
stage, so a plain `docker build .` cannot accidentally ship the test stage.

### `exec` in the CMD is load-bearing

```dockerfile
CMD exec uvicorn app.main:app --host 0.0.0.0 --port 8000 --workers ${WORKERS:-2}
```

Shell form is needed to expand `${WORKERS}` at start time, but without `exec`
the shell stays PID 1 and uvicorn runs as its child — so the SIGTERM that ECS
sends to stop a task lands on `/bin/sh` and is never forwarded. The container
would ignore the shutdown, wait out the stop timeout, get SIGKILLed, and drop
in-flight requests on **every deploy and every scale-in**. With `exec`, uvicorn
is PID 1:

```console
$ docker stop fraud-api
stopped in 747 ms          # not 10s+
INFO:  Application shutdown complete.
```

### Container performance

| mode | container | native | |
|---|---|---|---|
| single (1 txn/request) | 3,108 pred/s, p99 10.2 ms | 4,120 pred/s, p99 6.7 ms | 75% |
| batch (500 txns/request) | 66,752 pred/s | 62,544 pred/s | 107% |

The single-request gap is **Docker Desktop on macOS, not the image**: containers
run inside a Linux VM, so every port-forwarded request crosses the VM boundary.
That per-request cost dominates single mode (many small requests) and is
negligible in batch mode (few large ones) — which is exactly the pattern above,
and why batch is marginally *faster* in the container. On Linux hosts and on
Fargate there is no such boundary.

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
- [x] **Phase 2 — Docker.** Multi-stage build, 382 MB, in-image test stage.
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
├── Dockerfile              # multi-stage: builder / base / test / runtime
├── .dockerignore
└── .github/workflows/ci.yml
```
