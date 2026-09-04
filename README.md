# Credit Card Fraud Detection — Real-Time Inference API

A FastAPI service that scores credit-card transactions for fraud in real time,
serving an XGBoost model exported to ONNX. Sustains **~4,100 single-transaction
predictions per second at a p99 of 6.7 ms** on a 2020 M1 MacBook Air.

**Status: Phases 1–2 complete** (model + API + Docker). **Phase 3** — the AWS
stack in [`infra/`](infra/) — is written and `terraform plan`-verified at 61
resources, but has not been applied yet; see
[Project status](#project-status).

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

## AWS deployment

Terraform in [`infra/`](infra/) stands up ECS Fargate behind an Application Load
Balancer across two availability zones, deployed blue/green by CodeDeploy from
GitHub Actions over OIDC. 61 resources, one flat root module, no NAT gateway.

The claim this section supports is **multi-AZ, zero-downtime deploys with
automated rollback**, and every design choice below is in service of making the
second half of that literally true rather than aspirational.

```
                        Internet
                            │
                     :80    │
                   ┌────────▼─────────┐
                   │  ALB (public)    │  alb_sg: :80 from 0.0.0.0/0
                   │  2 public subnets│  :8080 test listener (CodeDeploy)
                   └───┬──────────┬───┘
          blue TG      │          │      green TG
                       │          │
        ┌──────────────▼──┐    ┌──▼──────────────┐
        │  AZ-a (private) │    │  AZ-b (private) │   task_sg: :8000
        │  Fargate task   │    │  Fargate task   │   ONLY from alb_sg
        │  no public IP   │    │  no public IP   │   (by SG id, not CIDR)
        └────────┬────────┘    └────────┬────────┘
                 │                      │
                 └──────────┬───────────┘
                            │  :443 only
              ┌─────────────▼──────────────┐
              │  VPC endpoints (no NAT,    │   ecr.api  ┐ interface
              │  no egress to the internet)│   ecr.dkr  ┤ endpoints
              │                            │   logs     ┘
              └────────────────────────────┘   s3 ──── gateway (free)
```

### The tasks have no route to the internet

Not "private subnets behind a NAT" — the private route tables contain no
`0.0.0.0/0` entry at all, and there is no NAT gateway in the VPC. Nothing on the
internet can initiate a connection to a task, and a task cannot initiate one
outbound either.

That is affordable because the application needs nothing from the internet: the
model is baked into the image and no request path calls an external service.
Everything the *platform* needs is reached over PrivateLink from inside the VPC:

| endpoint | type | why |
|---|---|---|
| `ecr.api` | interface | ECR authentication and metadata |
| `ecr.dkr` | interface | the Docker registry protocol |
| **`s3`** | **gateway** | **ECR image layers are stored in S3** |
| `logs` | interface | CloudWatch Logs, for the `awslogs` driver |

The S3 gateway endpoint is the one that gets forgotten, and its absence fails in
the least helpful way possible: `ecr.api` and `ecr.dkr` resolve, authentication
succeeds, the manifest is fetched — and then the pull hangs and the task dies,
because the *layers* come from S3. It is free, and it attaches to route tables
rather than subnets, which is why it does not look like the other three.

It has a second-order trap that is easy to miss even after adding it. A gateway
endpoint is a **route**, not an ENI, so its traffic is not covered by the task's
egress rule to the endpoint security group — it leaves towards S3's public
address range. Locking task egress down to `endpoint_sg` alone therefore
reproduces the exact failure the S3 endpoint was added to prevent. The task
group needs an explicit egress rule to the S3 managed prefix list
([`security.tf`](infra/security.tf)).

No ECS control-plane endpoint is needed: on Fargate platform 1.4.0 that traffic
is carried outside the customer VPC, and only image pulls and log delivery
traverse the task ENI.

**This costs more than a NAT, not less.** Interface endpoints bill per AZ, so
3 × 2 = 6 ENIs at ~$0.01/hr is **$0.06/hr** against a single NAT gateway's
$0.045/hr — about +$11/month. The trade is ~$0.015/hr to remove internet egress
entirely.

### Strict security groups

```
alb_sg       ingress :80   from 0.0.0.0/0          ← the one CIDR rule
             egress  :8000 → task_sg
task_sg      ingress :8000 ← alb_sg                 by SG id, never CIDR
             egress  :443  → endpoint_sg
             egress  :443  → S3 prefix list         image layers
endpoint_sg  ingress :443  ← task_sg
```

Every rule in the mesh references another security group **by ID**. The only
CIDR-based rule in the stack is the ALB's `:80` from the internet, which is the
one place it belongs. That is the point: "unreachable except through the ALB"
becomes a structural property of the graph rather than an arithmetic claim about
address ranges, and it stays true if the subnets are ever renumbered.

No SSH anywhere. No `0.0.0.0/0` ingress on tasks. `assign_public_ip = false`.
The CodeDeploy test listener on `:8080` is closed by default — CodeDeploy only
re-points it, it never connects to it, so leaving it open would add a second
internet-facing entry point for nothing. Set `test_listener_allowed_cidrs` to
your own address to hand-validate a green task set during the bake window.

`scripts/verify-deployment.sh` asserts all of this against the live account
rather than describing it.

### Blue/green deployments with automatic rollback

A deployment stands up a complete second task set on production-identical
infrastructure, health-checks it behind the test listener, then shifts
production traffic to it as a **canary** — 10% for five minutes, then the rest —
and keeps the old task set alive for a five-minute bake afterwards. If an alarm
trips at any point, traffic shifts **back** — to tasks that are already running
and already warm, so the rollback is a load-balancer operation rather than a
fresh deployment.

**Canary rather than all-at-once, and that choice is the "zero downtime"
claim.** All-at-once moves 100% of traffic onto the replacement task set and
*only then* does the 5XX alarm need a full 60-second period to breach before
rollback begins. That is a genuine one-to-three minute outage — precisely the
thing this phase exists to prove does not happen. Under canary only 10% of
requests ever reach a bad build, the alarm fires on exactly the same signal, and
the claim is true rather than aspirational. The cost is a ~6-minute deployment
instead of a ~1-minute one, and ~11 minutes of workflow wall-clock once the bake
window is included. That duration is the feature.

This is also why there is no separate staging environment. The green task set
*is* a pre-production deployment on production infrastructure, which is a
strictly more faithful rehearsal than a second, smaller stack; and a second
environment would double the ALB, the dominant cost line. An `environment`
variable keeps a second stack one `-var-file` away.

Two alarms are wired into the rollback trigger — `HTTPCode_Target_5XX_Count` and
p99 `TargetResponseTime` — both scoped to the **load balancer** dimension, not to
a target group. Under blue/green the production target group alternates on every
deployment, so a target-group-scoped alarm would spend half its life watching
the idle group.

`UnHealthyHostCount` is monitored but deliberately **not** in the rollback set,
which is a departure from the phase plan worth stating. A blue/green deployment
necessarily registers a fresh, not-yet-healthy task set into the standby target
group; those tasks are legitimately unhealthy for the ~45 s it takes ORT to load
and two health checks to pass. Wired to rollback, that alarm would fire on a
deployment's own normal startup and roll back good releases — it would be
measuring the deployment rather than the application. The 5XX and latency alarms
have no such coupling, because they only observe traffic that was actually
routed.

**No traffic, no alarm — and this is a trap, not a footnote.** Both rollback
alarms are `treat_missing_data = "notBreaching"`, and they have to be: an idle
load balancer emits no datapoints, which would park them in
`INSUFFICIENT_DATA`, and CodeDeploy refuses to start a deployment whose alarms
it cannot evaluate. The consequence is that **an idle ALB can never breach
either alarm** — a genuinely broken build deploys clean and CodeDeploy reports
success. Any rollback demonstration therefore requires load running through the
load balancer *for the duration of the deployment*, not before it.

Two more traps, both of which show up as *permanent diffs* rather than errors:

- Once `deployment_controller = CODE_DEPLOY`, CodeDeploy owns the service's task
  definition and load-balancer configuration. Terraform still holds revision 1
  and the blue target group in state, so without
  `lifecycle { ignore_changes = [task_definition, load_balancer, desired_count] }`
  every plan after every deployment proposes reverting the running service to
  the bootstrap image. This is the single most common way this setup breaks.
- CodeDeploy rewrites the listeners' `default_action` on every traffic shift —
  that swap *is* the deployment — so both listeners ignore changes to it too.

### Autoscaling on CPU, not request count

Target tracking, min 2 / max 6, on `ECSServiceAverageCPUUtilization`.

`ALBRequestCountPerTarget` reads better on paper and was the original choice,
but its `resource_label` has to name a *specific* target group — and under
blue/green the production target group swaps on every deployment. The policy
would be pointing at the idle group half the time, scaling on a metric that had
gone to zero. CPU has no coupling to the deployment mechanism at all.

The 60% setpoint is a placeholder until per-task capacity is measured on
Fargate. The local numbers (4,120 pred/s on an M1) will not transfer to 0.5 vCPU
on amd64, and a threshold guessed ahead of the measurement is just a number.

**Autoscaling that is configured but never driven is invisible**, and
"did you ever actually see it scale?" is a guaranteed question.
`scripts/benchmark.py` already takes a `--url`, so pointing it at the ALB and
holding enough load to breach the CPU target is nearly free — which is why the
scale-out is on the evidence list rather than assumed.

**The alarm thresholds are the same problem with higher stakes**, because they
gate every deployment. Set `alarm_p99_latency_seconds` or `alarm_5xx_threshold`
too tight and every deploy rolls itself back, which reads as CodeDeploy being
broken; too loose and the rollback demonstration never fires. The correct
sequence is **apply → benchmark through the ALB → set the thresholds from the
measurement → then attempt the rollback demo**.

### Access logs and a budget

**ALB access logs to S3**, seven-day expiry, pennies at this volume. The
application's own logs live and die with the task set; after a rollback the task
that served the bad requests is gone, and the bucket is the only remaining
per-request record of what it was asked and what it answered. It also turns "how
would you investigate a bad request after the fact" into a bucket rather than a
shrug.

One trap: which principal is allowed to write depends on how old the region is —
regions enabled before August 2022 (`us-east-1` among them) are written to by a
per-region ELB account, newer ones by a service principal — and getting it wrong
produces *silence*, not an error. The bucket policy grants both.

**An AWS Budgets alarm**, account-wide, $20/month by default. It is free, and it
mitigates the risk this stack actually has, which is not the hourly rate but
forgetting it is up. Account-wide rather than tag-filtered on purpose:
tag-based cost filters need cost allocation tags activated by hand and take up
to 24 hours to start matching, which is exactly long enough to be useless for
the window that matters. Set `budget_notification_email` or nothing is
delivered — it has no default because an address committed to a public
repository is a mailing list waiting to happen.

### Deployment pipeline

`.github/workflows/deploy.yml` runs after `ci.yml` passes on `main`:

```
1. checkout the commit CI actually tested   ← workflow_run.head_sha, not github.sha
2. assume the deploy role via OIDC          ← no stored access keys
3. docker build --target test  --platform linux/amd64   ← THE GATE
4. docker build --target runtime --platform linux/amd64
5. push, tagged with the git SHA, never :latest
6. render the live task definition with the new image
7. CodeDeploy blue/green deployment via .aws/appspec.yaml
8. wait for the deployment to settle, then smoke-test through the ALB
```

Step 3 is not redundant with `ci.yml`'s test job. That job runs pytest on the
**runner**, against runner-installed wheels. This runs the same suite **inside
the linux/amd64 image being shipped**. Local builds are arm64 and this image is
never built on the laptop, so CI is the only place the actual artifact gets
exercised before it reaches AWS.

`workflow_run` has a trap of its own: the workflow file and the default
`github.sha` come from the **default branch**, not from the commit that
triggered CI. Every step that needs the tested commit uses
`workflow_run.head_sha` explicitly.

Authentication is GitHub OIDC — there is no AWS access key in this repository.
The trust policy is scoped to the repository **and the ref**:

```
repo:JWanderer73/credit-card-fraud:ref:refs/heads/main
```

`repo:owner/name:*` is what most tutorials show, and it is a real hole: any
branch, and any fork pull request that manages to run a workflow, could assume a
role that pushes images and starts production deployments.

`iam:PassRole` is scoped to exactly the two task roles and conditioned on
`iam:PassedToService`. Unscoped, it would let whoever holds it register a task
definition running any image under *any* role in the account — an account
takeover dressed up as a deployment.

The **task role is empty on purpose**. The application makes no AWS API calls:
the model is in the image, configuration arrives as environment variables, and
logs are shipped by the `awslogs` driver under the *execution* role. Creating
the role and attaching nothing says that deliberately; attaching something "just
in case" would be the failure.

### Deploying it

```bash
# once per account: state bucket + infra/backend.hcl
./scripts/bootstrap-state.sh
terraform -chdir=infra init -backend-config=backend.hcl

# 1. first apply: empty service, nothing to pull yet
terraform -chdir=infra apply -var-file=envs/prod.tfvars \
  -var bootstrap=true -var budget_notification_email=you@example.com

# 2. hand the deploy role to GitHub — not a secret; it is useless without an
#    OIDC token whose `sub` matches the trust policy
gh variable set AWS_DEPLOY_ROLE_ARN \
  --body "$(terraform -chdir=infra output -raw github_actions_role_arn)"

# 3. build, push and deploy a real image
gh workflow run deploy.yml

# 4. second apply: autoscaling appears and fills the service to 2 tasks
terraform -chdir=infra apply -var-file=envs/prod.tfvars \
  -var budget_notification_email=you@example.com
```

**Step 1 is `bootstrap=true` for a reason.** `image_tag` defaults to
`bootstrap` against an empty, `IMMUTABLE` ECR repository, so a normal first
apply creates a service at `desired_count = 2` whose tasks can never pull an
image — it churns failed launches until the first workflow run pushes a real
SHA. Not fatal, but a confusing twenty minutes if it is hit unprepared.
`bootstrap=true` starts the service at zero tasks and skips the autoscaling
target, which would otherwise immediately drag it back up to its floor.

**Step 4 is what raises the service, and it has to be** — `desired_count` is in
the service's `ignore_changes` list because Application Auto Scaling owns it, so
it is `min_capacity` that fills the service to two tasks, not Terraform.

State locking uses S3 native conditional writes (`use_lockfile = true`), which
needs Terraform ≥ 1.10 and removes the DynamoDB lock table this stack would
otherwise carry — one fewer resource, and one fewer thing to forget to destroy.

### Demonstrating the rollback

The evidence worth capturing is not that the mechanism exists but that it works.
**There are two rollback paths and they are not interchangeable:**

| broken how | what CodeDeploy sees | what rolls it back |
|---|---|---|
| container will not start | green tasks never pass the ALB health check on `/ready`, so **traffic never shifts** | `DEPLOYMENT_FAILURE` — the deployment times out |
| container starts, `/ready` returns 200, inference returns 500 | green tasks look healthy, **the canary shifts 10% of traffic**, then real requests fail | `DEPLOYMENT_STOP_ON_ALARM` — the 5XX alarm breaches |

The first is the boring one: nothing bad ever reaches a user, but the alarms and
the `alarm_configuration` block are never touched. It shows that the load
balancer refuses to promote a dead task set — not that the rollback wiring
works. **The headline demo is the second**, because it exercises the whole
chain: alarm → CodeDeploy → traffic shifted back to blue tasks that are still
running and still warm.

Both are driven from `workflow_dispatch`, and **neither needs a throwaway
image** — each is one environment override on the rendered task definition:

```bash
# path 1 — dies at startup, traffic never shifts
gh workflow run deploy.yml -f simulate_failure=startup

# path 2 — the headline. Start load FIRST and leave it running.
python scripts/benchmark.py --url http://<alb-dns> --duration 900 &
gh workflow run deploy.yml -f simulate_failure=runtime
```

| mode | override | path exercised |
|---|---|---|
| `startup` | `MODEL_PATH=/srv/models/does-not-exist.onnx` | `FraudModel.load` raises in the lifespan handler, the process exits, `/ready` never answers → `DEPLOYMENT_FAILURE` |
| `runtime` | `FAULT_INJECT_PREDICT=true` | container starts, `/ready` returns 200, the task set is promoted, the canary shifts 10% of traffic onto it, *then* inference 500s → `DEPLOYMENT_STOP_ON_ALARM` |

**Why a chaos hook rather than just more bad configuration.** No environment
variable can produce the `runtime` shape on its own: model path, metadata path
and the feature-count check are all validated inside `FraudModel.load`, so every
misconfiguration kills the process at startup and collapses into the `startup`
row. Producing a task that is *healthy and wrong* requires the application's
cooperation. `FAULT_INJECT_PREDICT` ([app/config.py](app/config.py)) is that
cooperation: default off, checked in the shared `_predict` path so it covers
both inference routes, deliberately below `/health` and `/ready` so the task
still passes its health check, and logged loudly at startup so a task running
with it enabled is never a mystery. Three tests pin the two properties that
matter — that it is off unless asked for, and that when on it fails inference
*without* failing readiness.

And the thing that makes or breaks the demo: **run load through the ALB for the
duration of the `runtime` deployment.** With `notBreaching` on both alarms, no
traffic means no datapoints means no breach, and the broken build is reported as
a success.

### Verifying it

```bash
./scripts/verify-deployment.sh
```

Asserts, and exits non-zero on any violated claim:

1. `/ready` and `/docs` answer through the load balancer
2. the task security group has **no** CIDR ingress rule, and its only ingress
   source is the ALB's security group
3. no private route table has a `0.0.0.0/0` route, and the VPC contains no NAT
   gateway
4. no task ENI has a public IP; tasks occupy ≥ 2 availability zones; a direct
   connection to a task's private address from outside the VPC does not succeed
5. no alarm is in `ALARM`, and application logs are reaching CloudWatch

The rest of the evidence is captured by hand, in this order — the benchmark has
to come before the thresholds, and the thresholds before the rollback demo:

1. `terraform plan` / `apply` output
2. `curl <alb-dns>/ready` and `/docs` through the load balancer
3. **benchmark through the ALB** — the first number measured against real
   infrastructure rather than localhost, reported alongside the local 4,120/s
4. `./scripts/verify-deployment.sh` for the security claims
5. **the rollback, recorded rather than screenshotted** — `simulate_failure:
   runtime` with load running, showing the canary shift, the 5XX alarm
   breaching, and traffic going back to the still-warm blue task set. A
   forty-second clip is worth more than any paragraph about it, and it is the
   artifact that survives teardown. Run `simulate_failure: startup` too; it is
   one more dispatch and it shows the other path
6. **autoscaling actually scaling** — hold load until the CPU target is
   breached, capture the scale-out from 2 tasks, then the scale-in
7. multi-AZ: tasks in two AZs; stop one and show the ALB routing on
8. CloudWatch logs, and the alarms back in `OK`
9. `terraform destroy`, and the budget confirming spend returned to zero

### Cost and teardown

| item | ~hourly | ~monthly |
|---|---|---|
| ALB | $0.0225 | $16 |
| VPC interface endpoints (3 × 2 AZs) | $0.060 | $44 |
| S3 gateway endpoint | free | free |
| Fargate 2 × (0.5 vCPU / 1 GB) | $0.049 | $36 |
| ECR + CloudWatch | negligible | ~$1 |
| **total** | **~$0.13/hr** | **~$97/mo** |

Approximate, `us-east-1`. A few hours of evidence capture costs well under a
dollar; the risk is leaving it standing, not running it.

```bash
terraform -chdir=infra destroy -var-file=envs/prod.tfvars
```

The ALB and the interface endpoints are what accrue cost. The state bucket is
outside Terraform and survives; ECR and the access-log bucket are `force_delete`
/ `force_destroy` so `destroy` completes without a manual sweep, and the workflow
re-pushes on the next deploy.

#### The stack is destroyed; the artifact is the repository

At ~$97/mo this cannot be left running, so **there is deliberately no live demo
URL** — which is also what settles the HTTPS decision below, and what makes the
evidence capture the actual deliverable rather than a formality. What ships:

- **This README**, with the architecture, the security-group mesh, and the
  benchmark measured through the ALB alongside the local number.
- **The rollback recording** — the one piece of evidence that proves a mechanism
  rather than a configuration.
- **The Terraform**, which is one `apply` away from standing the whole thing up
  again.

"It is destroyed because it costs $97/mo — here is the plan output and the
recording" is a better answer than a link to a running toy, and it is the honest
one.

### Known gaps

- **HTTP only.** ACM certificates require a domain to validate against, and a
  domain only pays for itself if a URL stays live. This stack is destroyed after
  evidence capture, so there is no lasting URL for a certificate to protect —
  the deliverable is a recording, not a link. Adding TLS is a certificate ARN, a
  `:443` listener with an `ssl_policy`, and redirecting `:80` to it; the
  structure above does not change.
- **Autoscaling thresholds are unmeasured.** 60% CPU is a placeholder; the
  measurement on Fargate is the thing that should set it.
- **One region.** Multi-region would need Route 53 health-check failover and a
  replicated ECR, which is a different project.

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

34 tests, run with **only** numpy + onnxruntime + pytest — no dataset, no
training stack. The 150 MB CSV is gitignored and never reaches CI, so the suite
verifies the *committed artifact* in the same shape the Docker image provides.

`models/parity_fixture.json` (248 holdout rows with the probabilities the
trained sklearn pipeline produced for them) is what makes that possible.

Three of the 34 cover `FAULT_INJECT_PREDICT`, the chaos hook that drives the
rollback demonstration. It lives in the production inference path, so two
properties have to hold and keep holding: it is off unless explicitly asked for,
and when it is on it fails inference **without** failing `/health` or `/ready` —
a task that also went unready would be caught by the load balancer and would
never exercise the alarm the demonstration is about.

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
- [x] **Phase 3 — AWS.** Terraform (61 resources), ECS Fargate across 2 AZs
      behind an ALB, no NAT and no internet egress, CPU target-tracking
      autoscaling, CodeDeploy blue/green canary with alarm-driven auto-rollback,
      and a GitHub Actions OIDC deploy with no stored credentials. Written and
      plan-verified; the stack is applied for evidence capture and then
      destroyed.

**On wording.** The claim worth making is **"multi-AZ, zero-downtime deploys
with automated rollback"** — not "highly available." It is more specific, it is
entirely true, and it steers the conversation towards the part that was actually
built. "Highly available" is a single-region claim here and invites a
region-failure question this stack does not answer. Either way it only becomes
true at Phase 3 (2 AZs, ≥2 tasks); Phases 1–2 do not support it on their own.

## Repository layout

```
├── src/train.py            # train, tune threshold, export ONNX, verify parity
├── src/evaluate.py         # metrics report for the ONNX artifact
├── app/main.py             # FastAPI app, lifespan, routes
├── app/model.py            # ONNX Runtime session wrapper
├── app/schemas.py          # request/response models (30 named features)
├── app/config.py           # env-driven settings
├── tests/                  # 34 tests, runtime deps only
├── scripts/benchmark.py    # multi-process load generator
├── models/                 # committed: ONNX model, metadata, parity fixture
├── Dockerfile              # multi-stage: builder / base / test / runtime
├── .dockerignore
├── infra/                  # Terraform root module (flat, parameterized)
│   ├── versions.tf         # provider pins, S3 backend with native locking
│   ├── variables.tf
│   ├── network.tf          # VPC, subnets, routing — no NAT, no default route
│   ├── endpoints.tf        # ecr.api / ecr.dkr / logs interface, s3 gateway
│   ├── security.tf         # the three security groups, all SG-to-SG
│   ├── ecr.tf              # immutable tags, scan on push, lifecycle policy
│   ├── alb.tf              # ALB, blue/green target groups, prod + test listeners
│   ├── ecs.tf              # cluster, task definition, CODE_DEPLOY service
│   ├── autoscaling.tf      # CPU target tracking, 2–6 tasks
│   ├── codedeploy.tf       # blue/green, bake window, auto-rollback
│   ├── iam.tf              # GitHub OIDC, deploy/execution/task/CodeDeploy roles
│   ├── observability.tf    # log group, alarms, ALB access logs, budget
│   ├── outputs.tf
│   └── envs/prod.tfvars
├── .aws/appspec.yaml       # CodeDeploy ECS AppSpec
├── scripts/bootstrap-state.sh    # one-time: state bucket + backend.hcl
├── scripts/verify-deployment.sh  # asserts the security claims against AWS
├── .github/workflows/ci.yml
└── .github/workflows/deploy.yml  # OIDC → build → push → blue/green
```
