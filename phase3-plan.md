# Phase 3 — AWS Deployment Plan

Detailed plan for the final phase. Phases 1–2 are complete and pushed
(`1004e1a`, `a0505dc`). Nothing here is built yet.

This phase is what makes the **"highly available"** and **"automated AWS
deployment via GitHub Actions, configuring strict security groups"** clauses of
the project description true. Phases 1–2 do not support them on their own.

---

## The five deferred decisions — resolved

| # | Decision | Choice | Why |
|---|---|---|---|
| 1 | Task placement | **Private subnets + NAT** | Textbook answer and more defensible in an interview. ~$32/mo, but the stack is destroyed after evidence capture, so real cost is a few hours. |
| 2 | HTTPS | **HTTP-only** | ACM requires a domain we don't have. Documented as a known gap with the one-line change to add it. |
| 3 | CloudWatch | **7-day retention + alarms** | Alarms are not decorative here — they are the blue/green rollback trigger (see #4). |
| 4 | Deploy strategy | **Blue/green via CodeDeploy, auto-rollback** | No recurring cost (CodeDeploy for ECS is free, second target group is free). Makes the alarms load-bearing. The strongest talking point in the project. |
| 5 | Staging | **No staging; parameterized root module** | A second environment would double the ALB — the dominant cost line. Blue/green's green task set already *is* a pre-production deployment on production-identical infrastructure. An `environment` variable keeps a second stack one `-var-file` away. |

---

## Architecture

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
                 └───────► NAT ◄────────┘   egress only: ECR pull, CW logs
```

Traffic never reaches a task except through the ALB. Tasks have no public IP
and no inbound path from the internet.

---

## Bootstrap (manual, once)

Remote state has to exist before Terraform can use it, so this is done by hand:

- **S3 bucket** for state — versioning on, SSE enabled, public access blocked.
- **State locking.** Terraform ≥1.10 supports native S3 locking via
  `use_lockfile = true`, which removes the DynamoDB table entirely. *Verify the
  installed version at build time*; fall back to a DynamoDB lock table if older.
- Region: **us-east-1** (cheapest, and Fargate x86_64 is universally available).
- Tagging convention applied via provider `default_tags`: `Project`,
  `Environment`, `ManagedBy = terraform`.

`terraform` is **not installed** — `brew install terraform` is step zero.

---

## Terraform layout

```
infra/
├── versions.tf        # provider + backend config, pinned versions
├── variables.tf       # environment, region, sizing, repo name
├── network.tf         # VPC, subnets, IGW, NAT, route tables
├── security.tf        # the two security groups
├── ecr.tf
├── alb.tf             # ALB, 2 target groups, 2 listeners
├── ecs.tf             # cluster, task definition, service
├── autoscaling.tf
├── codedeploy.tf      # application, deployment group, rollback wiring
├── iam.tf             # OIDC provider + roles
├── observability.tf   # log group, alarms
├── outputs.tf
└── envs/prod.tfvars
```

**Deliberately a flat root module, not `modules/`.** Modules pay for themselves
when instantiated more than once; with a single environment they add a layer of
indirection and variable plumbing for no benefit, which is its own kind of
smell. The `environment` variable does the parameterization work. If a second
environment is ever added, the natural refactor is to wrap this in one `service`
module — worth saying out loud rather than pre-building the abstraction.

---

## Resources, with the traps called out

### Network
- VPC `10.0.0.0/16`; 2 public + 2 private subnets across 2 AZs.
- **Single NAT gateway**, not one per AZ. NAT is egress-only here — a running
  task serves ALB traffic without it. Losing the NAT's AZ does not take the
  service down; it prevents *new task launches* in that AZ (ECR pulls go
  through NAT). Halving $32/mo is worth that for a demo, but the reasoning
  should be stated, not hidden.
- *Alternative worth knowing:* VPC interface endpoints for ECR api/dkr + logs,
  plus a free S3 gateway endpoint, remove internet egress entirely. Cost is
  roughly a wash with NAT (~4 × $0.01/hr). Stronger security story, more
  resources to manage. Listed as an open sub-decision below.

### Security groups — the "strict" claim
This is the specific detail worth being able to explain, so it gets built
precisely:

- `alb_sg`: ingress `:80` from `0.0.0.0/0`; egress to `task_sg` on `:8000`.
- `task_sg`: ingress `:8000` **from `alb_sg` by security-group ID**, never by
  CIDR; egress `:443` for ECR and CloudWatch.
- No SSH anywhere. No `0.0.0.0/0` ingress on tasks. `assign_public_ip = false`.

Referencing by SG ID rather than CIDR is the point: it stays correct if subnets
change, and it makes "unreachable except via the ALB" a structural property
rather than an arithmetic one.

Use the modern per-rule resources (`aws_vpc_security_group_ingress_rule`)
rather than inline `ingress` blocks, which fight with out-of-band changes.

### ECR
- `scan_on_push = true`.
- `image_tag_mutability = IMMUTABLE` — pairs with git-SHA tagging so a tag can
  never silently point at different bytes.
- Lifecycle policy: expire untagged after 1 day, keep last 10 tagged.

### ALB
- Internet-facing across both public subnets.
- **Two target groups** (blue/green), `target_type = "ip"` — required for
  `awsvpc` networking; the common mistake is `instance`.
- Health check → **`/ready`**, not `/health`: `/ready` returns 503 until the
  ONNX session is loaded, so the ALB will not route to a task that would fail
  every request.
- `deregistration_delay = 30` (default 300 makes every deploy crawl).
- Production listener `:80` → blue TG. Test listener `:8080` → green TG.

### ECS
- Fargate, `0.5 vCPU / 1 GB`, **x86_64** (`runtime_platform`).
- `desired_count = 2`, spread across both AZs.
- `deployment_controller = "CODE_DEPLOY"`.
- `health_check_grace_period_seconds` set high enough to cover ORT session load.

> **Trap:** once the deployment controller is `CODE_DEPLOY`, CodeDeploy owns the
> service's task definition and load balancer config. Terraform will fight it on
> every plan unless the service has
> `lifecycle { ignore_changes = [task_definition, load_balancer] }`.
> This is the single most common way this setup breaks, and it shows up as
> perpetual diffs rather than an error.

### Autoscaling
- Target min 2, max 6.
- **CPU target tracking as the primary policy.** The plan originally favoured
  `ALBRequestCountPerTarget`, but that metric's `resource_label` must name a
  *specific* target group — and under blue/green the active target group swaps
  on every deploy. CPU avoids that whole class of breakage.
- Thresholds set from a **measured** per-task capacity on Fargate, not guessed.
  Local numbers (3,108 RPS containerized on an M1) will not transfer to
  0.5 vCPU; measuring it is a deliverable of this phase.

### IAM
- **GitHub OIDC provider** — no long-lived access keys anywhere.
- Trust policy scoped to the repo **and branch**:
  `repo:JWanderer73/credit-card-fraud:ref:refs/heads/main`. Scoping to the repo
  alone would let any branch or PR assume the deploy role.
  *(Verify whether `thumbprint_list` is still required by the provider version;
  AWS stopped requiring it for GitHub's endpoint.)*
- Deploy role: ECR push, ECS describe/register-task-definition, CodeDeploy
  create-deployment, and `iam:PassRole` **scoped to the two task roles** rather
  than `*`.
- Task execution role: pull from ECR, write logs.
- Task role: **empty**. The application makes no AWS API calls, and saying so
  deliberately is better than attaching something "just in case."

### CodeDeploy
- ECS application + deployment group.
- Traffic shift: `AllAtOnce` for demo speed, with a short bake before blue tasks
  terminate. (`Linear10PercentEvery1Minutes` is more realistic but makes every
  demo deploy ~10 minutes.)
- `auto_rollback_configuration` on `DEPLOYMENT_FAILURE` **and** `DEPLOYMENT_STOP_ON_ALARM`.
- `blue_green_deployment_config` with `terminate_blue_instances_on_deployment_success`
  wait time so there is a real window to observe both task sets.
- `appspec.yaml` with a `<TASK_DEFINITION>` placeholder the workflow substitutes.

### Observability
- Log group, **7-day retention** (default is never-expire, which quietly
  accrues cost).
- Alarms, wired into the CodeDeploy rollback trigger:
  - `HTTPCode_Target_5XX_Count` above threshold
  - `TargetResponseTime` p99 above threshold
  - `UnHealthyHostCount >= 1`

---

## `.github/workflows/deploy.yml`

```
on: push to main (after ci.yml passes)

permissions: { id-token: write, contents: read }

1. checkout
2. aws-actions/configure-aws-credentials  ← OIDC, no stored keys
3. ECR login
4. docker build --target test  --platform linux/amd64   ← GATE
5. docker build --target runtime --platform linux/amd64 -t $ECR:$GIT_SHA
6. docker push                                           ← SHA tag, never :latest
7. render task definition with the new image
8. CodeDeploy deployment via appspec
9. wait for deployment to complete
```

Step 4 is not redundant with `ci.yml`'s test job. That job runs pytest on the
**runner**; this runs the suite **inside the linux/amd64 image being shipped**.
Local builds are arm64 and this image is never built on the laptop, so CI is the
only place the actual artifact gets exercised before it reaches AWS. Skipping it
turns the arm64-local/amd64-CI split into exactly the "works on my machine" trap
it was designed to avoid.

---

## Verification — evidence to capture

1. `terraform plan` / `apply` output.
2. `curl <alb-dns>/ready` and `/docs` responding through the load balancer.
3. **Benchmark through the ALB** — the first number measured against real
   infrastructure rather than localhost. Report alongside the local 4,120 RPS.
4. **Prove the security claim:** `aws ec2 describe-security-groups` showing
   `:8000` ingress referencing only `alb_sg`, and tasks with no public IP.
   Then confirm the task IP is unreachable directly.
5. **Prove the rollback:** deliberately deploy a broken image and show
   CodeDeploy detecting it and shifting traffic back with zero downtime. This
   is the single most valuable piece of evidence in the phase — it demonstrates
   the mechanism actually works rather than merely existing.
6. Multi-AZ: tasks running in two AZs; kill one and show the ALB routing on.
7. CloudWatch logs and an alarm in OK state.
8. `terraform destroy`.

---

## Cost and teardown

| item | ~hourly | ~monthly |
|---|---|---|
| ALB | $0.0225 | $16 |
| NAT gateway | $0.045 | $33 |
| Fargate 2 × (0.5 vCPU / 1 GB) | $0.049 | $36 |
| ECR + CloudWatch | negligible | ~$1 |
| **total** | **~$0.12/hr** | **~$85/mo** |

Approximate, us-east-1. A few hours of evidence capture costs well under a
dollar; the risk is leaving it up, not running it.

```bash
terraform destroy    # documented in the README, not an afterthought
```

Keep the ECR images and the state bucket — both negligible. The ALB and NAT are
what accrue cost if the stack is left standing.

---

## Risks, ordered by likelihood

1. **CodeDeploy blue/green is the fiddliest part of the project.** Stuck
   deployments and AppSpec/task-definition mismatches are the classic failures.
   Budget more time here than for everything else in the phase combined.
2. **Terraform vs CodeDeploy ownership** of the ECS service (see the
   `ignore_changes` trap above) — shows up as perpetual diffs, not errors.
3. **First real amd64 execution.** Everything so far is arm64. The in-container
   test gate is the mitigation, and this is where it earns its keep.
4. **OIDC trust policy** too permissive (repo-wide instead of branch-scoped) is
   an easy and consequential mistake.
5. **NAT is required for ECR pulls** — a misconfigured route table produces
   tasks that hang on launch with an unhelpful error.
6. **Fargate capacity is unmeasured.** Autoscaling thresholds must follow the
   measurement, not precede it.

---

## Open sub-decisions

Small enough to decide at build time, but they change what gets written:

- **1 NAT vs 2** — plan assumes 1 (cost); 2 removes the task-launch SPOF.
- **VPC endpoints instead of NAT** — comparable cost, no internet egress at
  all, stronger security story, more resources.
- **Region** — plan assumes `us-east-1`.
- **Traffic shift config** — `AllAtOnce` (fast demos) vs linear (realistic).
- **Container Insights** — useful metrics, but it is not free.
