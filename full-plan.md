# Credit Card Fraud Detection — Real-Time Inference API

## Context

Goal is a portfolio project backing this description:

> Deployed a highly available machine learning inference API using Python and FastAPI, capable of serving **[X]** real-time predictions per second. Containerized the backend with Docker and automated AWS deployment via GitHub Actions, configuring strict security groups.

The repo started empty — no commits, only `archive.zip` containing the ULB credit card fraud dataset (284,807 rows; `Time`, `V1`–`V28`, `Amount`, `Class`; 492 frauds = 0.173% positive, confirmed: 284,315 legit / 492 fraud). Everything below is greenfield.

**Current state (uncommitted, unverified):** a partial start exists from before this plan was finalized — `.gitignore`, `requirements.txt`, `requirements-dev.txt`, `src/train.py`, a working `.venv`, and `data/creditcard.csv` extracted. `src/train.py` has **never been run end to end**; its ONNX export path is unproven. Phase 1 begins by validating it, not by assuming it works.

Three phases, built in order, **stopping for review after each one** (see [Phase gates](#phase-gates)). **Phase 1 and 2 are specified for execution; Phase 3 is an outline** with open decisions flagged for later.

`[X]` is deliberately left blank until Phase 1 — a benchmark script measures the real number and we fill it in. No made-up figure goes on the resume.

### Decisions already made
- **Phase 3 runtime:** ECS Fargate behind an ALB, 2 AZs, target-tracking autoscaling. Docker/ECR/multi-stage build are unchanged by this choice — the image is the only deployment unit.
- **IaC:** Terraform (not yet installed locally).
- **API shape:** `POST /predict` (single) + `POST /predict/batch`. Batch exists because ONNX Runtime amortizes per-call overhead heavily; it is what makes the throughput number impressive.
- **Response body:** `fraud_probability` + `is_fraud` + `threshold_used`.
- **Validation:** stratified 5-fold cross-validation, with threshold tuned on pooled out-of-fold predictions.
- **Hyperparameters:** `RandomizedSearchCV` scored on `average_precision` under the same `StratifiedKFold(5)`. `scale_pos_weight` sits *in* the search space as `{1, 24, 578}` rather than being fixed — PR-AUC is threshold-free, so the search judges fit rather than where a cutoff lands.
- **Search budget:** `--n-iter 150` (750 fits, ~15–60 min), run in the background while Phase 2 is written. Justified by the measured timings below.
- **Threshold policy:** maximize F1 on pooled OOF predictions; report precision and recall alongside.
- **Training location:** local. The search is minutes, not hours, and keeping `git clone && python src/train.py` reproducible is worth more than the time saved.
- **Architecture:** local builds are native **arm64** for fast iteration; GitHub Actions x86 runners build the **linux/amd64** image that actually deploys. Fargate stays x86_64.
- **Cadence:** hard stop after each phase with a written status report; next phase does not begin without approval.
- **Cost:** stack is spun up to capture evidence, then `terraform destroy`. Teardown is documented, not an afterthought.

### Environment constraints found
- Anaconda base env (`/opt/anaconda3`) has a **broken NumPy 1.x/2.4.4 ABI conflict** — `import sklearn` emits a compiled-module warning. Do **not** train in it. `.venv` is already created and working.
- Installed and verified in `.venv`: numpy 2.2.1, scikit-learn 1.5.2, **xgboost 2.1.3**, onnx 1.17.0, onnxruntime 1.20.1, skl2onnx 1.18.0, onnxmltools 1.13.0, fastapi 0.115.6. XGBoost is deliberately pinned to the 2.1.x line, not the current 3.4.1 — `onnxmltools`' XGBoost converter historically lags major releases.
- Docker CLI present, **daemon not running** — start Docker Desktop before Phase 2.
- `terraform` not installed — `brew install terraform` before Phase 3.
- AWS creds valid: account `<redacted>`, user `Jake`.
- Host is **arm64** (M1 MacBook Air, 8 cores, 8GB); Fargate is **x86_64**. See the architecture decision above — no local x86 emulation.

### Measured training cost (M1 Air, `tree_method="hist"`, one CV fold = 182,276 rows × 30)

| config | per fit | 150 fits (30 candidates) | 750 fits (150 candidates) |
|---|---|---|---|
| 200 trees, depth 4 | 1.14 s | 2.8 min | 14 min |
| 400 trees, depth 6 | 2.73 s | 6.8 min | 34 min |
| 800 trees, depth 8 | 4.65 s | 11.6 min | 58 min |

This is what settled the local-vs-cloud question: the dataset is small enough that tuning is a coffee break, and the full array is ~68MB against 8GB of RAM. Cloud training would add upload, environment reproduction, and artifact retrieval to save under an hour.

---

## Phase gates

**Work stops at the end of each phase.** No phase begins without explicit approval of the previous one's report.

At each gate I deliver a written status report containing:

1. **Built** — every file created, one line each on what it does.
2. **Verification results** — the actual commands run and their real output (test counts, metrics, image sizes, benchmark numbers). Pasted output, not claims.
3. **Metrics / numbers** — whatever that phase produced: per-fold and test PR-AUC for Phase 1, image size and RPS for Phase 2.
4. **Deviations** — anything built differently from this plan, and why. Version pins that had to change, approaches that didn't work.
5. **Known gaps** — what is explicitly not done yet, including anything from the phase that got blocked.
6. **Next phase preview** — what Phase N+1 starts with, and any decisions needed from you before it can begin.

Phase 3's gate additionally requires resolving the five deferred decisions listed in its section, since they change what gets written.

---

## Target layout

```
credit-card-fraud/
├── data/                       # gitignored — creditcard.csv extracted here
├── models/
│   ├── fraud_model.onnx        # COMMITTED (small, ~1-3MB)
│   └── metadata.json           # COMMITTED — feature order, threshold, metrics
├── src/
│   ├── train.py                # train + tune threshold + export ONNX
│   └── evaluate.py             # metrics report on held-out test set
├── app/
│   ├── main.py                 # FastAPI app, lifespan, routes
│   ├── model.py                # ORT session wrapper
│   ├── schemas.py              # pydantic request/response models
│   └── config.py               # env-driven settings
├── tests/
│   ├── test_api.py
│   ├── test_model.py           # includes ONNX↔sklearn parity
│   └── test_schemas.py
├── scripts/benchmark.py        # measures [X]
├── requirements.txt            # RUNTIME only — tiny
├── requirements-dev.txt        # training + test deps
├── Dockerfile                  # multi-stage
├── .dockerignore
└── .github/workflows/
    ├── ci.yml                  # Phase 1-2: tests + build check
    └── deploy.yml              # Phase 3
```

**The model artifact is committed to git.** It is small, the Docker image needs it, and CI must run tests without the 150MB CSV. `data/` and `archive.zip` are gitignored.

---

## Phase 1 — Model + FastAPI

### 1a. Dependency split (do this first — it drives Phase 2's image size)

This split is the single highest-leverage decision in the project.

**`requirements.txt` (runtime — what ships in the image):**
`fastapi`, `uvicorn[standard]`, `pydantic`, `numpy`, `onnxruntime`

**`requirements-dev.txt` (training/test only):**
`-r requirements.txt` plus `pandas`, `scikit-learn`, `xgboost`, `skl2onnx`, `onnxmltools`, `onnx`, `pytest`, `httpx`

Neither `xgboost` nor `scikit-learn` is needed to serve — ONNX Runtime executes the graph standalone. This is what takes the runtime image from ~1.5GB to well under 400MB, and it is the substance behind "eliminate non-essential build dependencies."

Every version is pinned; both files are already written. XGBoost is pinned to **2.1.3** rather than the current 3.4.1 because `onnxmltools`' XGBoost converter historically lags major releases. The parity test (1f) is the guard that catches a converter mismatch at build time rather than in production.

### 1b. Data prep
- `unzip archive.zip -d data/`, gitignore it.
- **Hold out a stratified 20% test set once**, `random_state` fixed. It is touched exactly one time, at the very end of 1c. All cross-validation happens on the remaining 80%.
- (Temporal split on `Time` is arguably more honest for fraud, but `Time` only spans 2 days here — stratified is the defensible standard for this dataset. Note the choice in the README.)

### 1c. Training (`src/train.py`) — stratified 5-fold CV

**Pipeline definition**
- `ColumnTransformer`: `StandardScaler` on `Time` + `Amount`; `passthrough` for `V1`–`V28` (already PCA outputs, pre-scaled).
- `XGBClassifier` wrapped in a `Pipeline` with the transformer. Fixed across all candidates: `tree_method="hist"`, `eval_metric="aucpr"`, `random_state=42`.
- The `ColumnTransformer` addresses columns by **integer index** (`[0, 29]`), not name, and is fit on numpy arrays. This matters for 1d: it lets the whole graph take a single `FloatTensorType([None, 30])` input in raw CSV column order instead of 30 separate named inputs.

Keeping the scaler **inside** the Pipeline is what makes CV valid — `StandardScaler` is refit on each fold's training portion only. Scaling before splitting would leak test-fold statistics into every fold and silently inflate every number below.

**CV loop** — `StratifiedKFold(n_splits=5, shuffle=True, random_state=42)`
- Stratification is not optional here. With 492 positives, unstratified folds can differ by tens of fraud cases and make fold metrics incomparable.
- For each fold: fit on 4/5, `predict_proba` on the held-out 1/5, store those probabilities as **out-of-fold (OOF) predictions**.
- Report **mean ± std PR-AUC across the 5 folds**. The std is the interesting part — it tells you whether the model is stable or whether one lucky fold is carrying the average. Log per-fold numbers, not just the mean.

**Early stopping under CV.** Early stopping needs a validation set, but using the held-out fold for it contaminates that fold's OOF predictions. Resolve by running early stopping **once** up front to find a reasonable `n_estimators`, then fixing that value for the CV loop with early stopping off. Simpler than nested CV and the mild optimism is bounded.

**Hyperparameter search** — `RandomizedSearchCV`, `n_iter=150`, `scoring="average_precision"`, same `StratifiedKFold(5)`, `refit=False` (we refit explicitly after threshold tuning):

| param | distribution | why |
|---|---|---|
| `max_depth` | `randint(3, 9)` | main capacity knob |
| `learning_rate` | `loguniform(0.02, 0.3)` | log scale — 0.02→0.05 matters as much as 0.1→0.3 |
| `subsample` | `uniform(0.6, 1.0)` | row sampling, regularizes |
| `colsample_bytree` | `uniform(0.6, 1.0)` | column sampling |
| `min_child_weight` | `randint(1, 11)` | guards against splits fitting a handful of frauds |
| `gamma` | `uniform(0, 5)` | min split loss |
| `reg_lambda` | `loguniform(0.1, 10)` | L2 |
| `max_delta_step` | `randint(0, 11)` | XGBoost docs specifically recommend a nonzero value for logistic objectives on extremely imbalanced data — underused and relevant here |
| `scale_pos_weight` | `{1, √578≈24, 578}` | see below |

**`scale_pos_weight` is searched, not fixed.** The three candidates are natural / geometric-mean / full-ratio. This is safe to search precisely because the scoring metric is PR-AUC, which is threshold-free: the search compares how well models *rank* transactions, not where a cutoff falls. The winner is recorded in `metadata.json` along with a calibration note — at `scale_pos_weight=578` the returned `fraud_probability` is deliberately *not* calibrated and overstates absolute fraud risk, even though ranking quality is unaffected.

`n_jobs=1` on the search, `n_jobs=-1` on XGBoost. Nesting both would oversubscribe the 8 cores and run slower, not faster.

**Metric: PR-AUC (`average_precision`), not ROC-AUC.** At 0.173% positives ROC-AUC is misleadingly flattering — every model scores ~0.97.

**Threshold tuning on pooled OOF predictions.** Concatenate the OOF probabilities from all 5 folds into one full-length prediction vector, then pick the threshold on *that* PR curve. This is the main payoff of using CV: the threshold is chosen against all 492 fraud cases instead of the ~98 a single validation split would offer, so it is far less likely to be an artifact of one split. Persist it in `metadata.json`. At this class balance the threshold is most of the model's real-world behavior.

**Final fit and honest evaluation**
1. Refit the pipeline on the full 80% with the same config → this is the model that gets exported to ONNX.
2. Evaluate once on the untouched 20% test set at the tuned threshold. **These are the numbers reported publicly** — CV metrics guided model and threshold selection, so they are no longer unbiased.

**`models/metadata.json`** records: ordered feature list, tuned threshold, per-fold CV PR-AUC + mean/std, held-out test metrics (PR-AUC, precision, recall, F1, confusion matrix), library versions, training timestamp.

### 1d. ONNX export
XGBoost is not natively known to `skl2onnx`; register the `onnxmltools` converter first:

```python
update_registered_converter(
    XGBClassifier, "XGBoostXGBClassifier",
    calculate_linear_classifier_output_shapes, convert_xgboost,
    options={"nocl": [True, False], "zipmap": [True, False, "columns"]},
)
onx = convert_sklearn(
    pipeline, initial_types=[("input", FloatTensorType([None, 30]))],
    options={id(pipeline): {"zipmap": False}},
)
```

`zipmap: False` is important — it yields a plain probability tensor instead of a list-of-dicts, which is both faster and far easier to handle in the API.

### 1e. FastAPI app
- Load the `InferenceSession` **once** in a `lifespan` handler, not per request.
- Session options: `intra_op_num_threads=1`, `GraphOptimizationLevel.ORT_ENABLE_ALL`. Threads pinned to 1 is deliberate — with multiple uvicorn workers, ORT's default thread pool oversubscribes cores and *reduces* throughput.
- Build the input array in the **feature order from `metadata.json`**, never from dict iteration order. Cast to `float32` explicitly.
- Endpoints:
  - `GET /health` — liveness, no model touch
  - `GET /ready` — 503 until session loaded (this is the ALB target-group check)
  - `POST /predict` — one transaction
  - `POST /predict/batch` — list, capped (e.g. 1000) to bound latency and memory
- `schemas.py`: explicit named `float` fields for all 30 features. Verbose, but it produces self-documenting OpenAPI at `/docs` — the part a reviewer actually clicks. Batch request wraps `list[Transaction]`.

### 1f. Tests
- **ONNX↔sklearn parity** (`test_model.py`): assert ORT probabilities match `pipeline.predict_proba` within `atol≈1e-4`. Exact equality will fail — the scaler runs in float32 in ONNX vs float64 in sklearn. This test is the contract that the serialized model is the model you trained.
- API tests via `TestClient`: happy path single + batch, `/health`, `/ready`, threshold logic at boundaries.
- Validation tests: missing field, wrong type, oversized batch → 422/413.

### 1g. Benchmark (`scripts/benchmark.py`)
Concurrent load against local uvicorn; report p50/p95/p99 latency and sustained RPS for single and batch modes separately. **Its output fills in `[X]`.** Quote the single-prediction RPS as the headline (honest for "real-time") and cite batch throughput separately.

---

## Phase 2 — Docker

### Dockerfile (multi-stage)
- **Stage 1 `builder`** — `python:3.12-slim`: create a venv, `pip install --no-cache-dir -r requirements.txt` (runtime deps only). No compilers needed; `onnxruntime` and `numpy` ship manylinux wheels.
- **Stage 2 `runtime`** — fresh `python:3.12-slim`: `COPY --from=builder` the venv, then `app/` and `models/`. No pip cache, no build toolchain, no training libraries.
- Non-root user (`useradd`), `PYTHONDONTWRITEBYTECODE=1`, `PYTHONUNBUFFERED=1`, `EXPOSE 8000`.
- `HEALTHCHECK` hitting `/health`.
- CMD: `uvicorn app.main:app --host 0.0.0.0 --port 8000 --workers ${WORKERS:-2}`.

### `.dockerignore` — required, not optional
Must exclude `data/`, `archive.zip`, `.git/`, `.venv/`, `tests/`, `__pycache__`. Without it Docker ships the 69MB zip and 150MB CSV into build context and the image.

The Dockerfile itself must stay **architecture-agnostic** — no hardcoded platform, no arch-specific wheel URLs. Platform is chosen at build time by whoever builds. `onnxruntime` and `numpy` both publish manylinux wheels for `aarch64` and `x86_64`, so the same Dockerfile works either way with no changes.

### Verification
- Start Docker Desktop first (daemon is down).
- Build **native arm64** locally (`docker build -t fraud-api .`, no `--platform`) — fast, no emulation. This is the image you iterate against.
- Record `docker images` size — target < 400MB — and note the delta vs a naive single-stage build including sklearn+xgboost. That difference is the concrete evidence for "eliminate non-essential build dependencies."
- Re-run `scripts/benchmark.py` against the container and compare to the bare-uvicorn numbers.

**Closing the arch gap.** The amd64 image is never built locally, so it must be tested where it *is* built. Phase 3's CI runs `pytest` **inside** the built amd64 container as a gate before the ECR push — the shipped artifact gets tested, just in CI rather than on your laptop. This is what makes the arm64-local/amd64-CI split safe rather than a "works on my machine" trap, and it needs to exist in `deploy.yml` from the start.

---

## Phase 3 — AWS (outline; refine later)

Terraform, ECS Fargate, 2 AZs, ALB, target-tracking autoscaling. **Not fully specified — this is the shape, with open decisions listed.**

### Bootstrap (once, by hand)
S3 bucket for Terraform state + DynamoDB table for locking.

### Terraform modules
1. **Network** — VPC across 2 AZs. *Cost decision:* placing tasks in public subnets with `assign_public_ip` and a restrictive SG avoids a NAT Gateway (~$32/mo). Private subnets + NAT is the textbook answer and more defensible in an interview. Flagged for your call.
2. **ECR** — repo with scan-on-push and a lifecycle policy expiring untagged images.
3. **ALB** — public, listener → target group on 8000, health check `/ready`.
4. **ECS** — cluster, task definition (Fargate, ~0.5 vCPU / 1GB), service with `desired_count = 2` spread across AZs.
5. **Autoscaling** — Application Auto Scaling target tracking on `ALBRequestCountPerTarget` and/or CPU; min 2, max ~6.
6. **Security groups — the "strict" claim.** ALB SG: 80/443 inbound from internet. Task SG: port 8000 inbound **only from the ALB security group**, referenced by SG ID, never by CIDR. Tasks are unreachable directly from the internet. This is the specific detail worth being able to explain.
7. **IAM** — GitHub Actions assumes a role via **OIDC**, no long-lived access keys in repo secrets. Plus ECS task execution role and task role, least-privilege.

### `.github/workflows/deploy.yml`
`pytest` on the runner → build `--platform linux/amd64` on the native x86 runner → **`pytest` again inside the built container** → push to ECR tagged with the **git SHA** (not `latest`) → render new task definition → `aws ecs update-service` → wait for service stable. Deploy gated on both test runs passing and on `main`.

The in-container test run is not redundant with the first: it is the only place the amd64 artifact is exercised before it reaches AWS.

### Teardown
`terraform destroy` documented in the README, plus a note on what accrues cost if left up (ALB ~$16/mo dominates). Keep ECR images and TF state — both negligible.

### Open decisions deferred to you
- Public-subnet tasks vs private + NAT (cost vs. best practice)
- HTTPS: ACM cert + domain, or HTTP-only demo
- CloudWatch alarms / log retention period
- Rolling update vs blue-green (CodeDeploy)
- Whether a staging environment is worth the Terraform workspace complexity

---

## Verification

**Phase 1**
1. `.venv` is already built and verified — skip to step 1a.
1a. **Smoke-test first:** `python src/train.py --skip-search` (~2 min). This exercises the entire path — load, CV, threshold, refit, ONNX export, parity check — without paying for the search. The ONNX conversion is the least-proven step in the project and this is where it will fail if it's going to.
2. Then the real run: `python src/train.py --n-iter 150`, backgrounded (~15–60 min). Writes `models/fraud_model.onnx` + `metadata.json`. Held-out test PR-AUC should land ~0.80–0.88, and the 5 fold PR-AUCs should sit within roughly ±0.05 of each other — a wide spread means the folds are not comparable and something is wrong with the split.
3. `pytest -v` — all pass, **including the ONNX parity test**.
4. `uvicorn app.main:app --reload`, open `/docs`, POST a known-fraud row from the CSV and confirm high `fraud_probability`; POST a known-normal row and confirm low.
5. `python scripts/benchmark.py` → record RPS.

**Phase 2**
6. `docker build -t fraud-api .` (native arm64) then `docker images` — confirm < 400MB.
7. `docker run -p 8000:8000 fraud-api`, re-run steps 4–5 against the container; results should match.
8. `docker run --rm fraud-api pip list` — confirm **no** sklearn/xgboost/pandas in the runtime image. This is the direct evidence for the dependency-split claim.

**Phase 3** — deferred until the outline is refined.

Each block above ends at a [phase gate](#phase-gates): I stop, report, and wait.

---

## Notes / risks
- **`[X]` stays blank until step 5 measures it.** Report single-prediction RPS as the headline number.
- `onnxmltools` ↔ `xgboost` version compatibility is the most likely thing to break in Phase 1; the parity test catches it at build time.
- "Highly available" is only true once Phase 3 lands (2 AZs, ≥2 tasks). Phase 1–2 alone don't support that clause of the description.
- arm64 host vs x86_64 Fargate — the mitigation is CI testing the amd64 image in-container, not local emulation. If that CI step is skipped, this becomes a real "works on my machine" risk.
- **If the winning `scale_pos_weight` is 578, `fraud_probability` is not calibrated** and overstates absolute risk. Ranking and PR-AUC are unaffected, but the README must say so — a returned 0.7 would not mean "70% of such transactions are fraud." Revisit if calibrated probabilities turn out to matter for the demo.
- The threshold is tuned on OOF predictions from the same folds used for hyperparameter selection, so it carries mild optimism. The untouched holdout test set is what catches it — which is why those, not the CV numbers, are the reportable figures.
- `src/train.py` exists but is **unrun**. Treat its correctness as unverified until step 1a passes.
