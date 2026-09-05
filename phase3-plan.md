# Phase 3 — AWS Deployment Plan

> **This is the original plan, kept as written. It is superseded in places.**
>
> Phase 3 was built, run against AWS, and torn down. Several things in this
> document turned out to be wrong or impossible, and the record of what actually
> happened is **[`docs/evidence.md`](docs/evidence.md)**, with the design as
> built described in the [README](README.md#aws-deployment).
>
> The three largest divergences:
>
> - **CodeDeploy could not be used.** The AWS account cannot subscribe to it
>   (`SubscriptionRequiredException`), so the stack uses ECS-native canary
>   deployments instead. Everything this document says about CodeDeploy
>   applications, deployment groups, appspec files and `DEPLOYMENT_FAILURE`
>   describes a design that was never deployed.
> - **"Rolls back on deployment failure" was wrong for the startup case.** ECS's
>   alarms only observe traffic that was routed, and a task set that never goes
>   healthy receives none — so a broken startup churned for 29 minutes with no
>   recovery. That needed `deployment_circuit_breaker`, which this plan does not
>   mention.
> - **The autoscaling thresholds here were guesses, and the first measurement of
>   them was also wrong.** `AWS/ECS CPUUtilization` is a one-minute average, so
>   the 60-second benchmark runs understated CPU by a third.
>
> Kept rather than rewritten because the reasoning that survived contact is more
> useful next to the reasoning that did not.


Detailed plan for the final phase. Phases 1–2 are complete and pushed
(`1004e1a`, `a0505dc`). The Terraform, both workflows, the appspec and the
verification script are **written but not yet applied against AWS** — nothing
in this plan has been proven against real infrastructure.

This phase is what makes the **"highly available"** and **"automated AWS
deployment via GitHub Actions, configuring strict security groups"** clauses of
the project description true. Phases 1–2 do not support them on their own.

**Wording, for the README and the resume line:** say **"multi-AZ, zero-downtime
deploys with automated rollback,"** not "highly available." It is more specific,
it is entirely true, and it steers the conversation towards the part that was
actually built. "Highly available" is a single-region claim here and invites a
region-failure question that this stack does not answer.

---

## The five deferred decisions — resolved

| # | Decision | Choice | Why |
|---|---|---|---|
| 1 | Task placement | **Private subnets + VPC endpoints, no NAT** | Tasks get *no route to the internet at all* — strictly stronger than "private subnets behind a NAT." Costs ~$0.015/hr more than a NAT (endpoints bill per AZ), which is immaterial for a stack that is destroyed after evidence capture. |
| 2 | HTTPS | **HTTP-only** | ACM needs a domain, and a domain only pays for itself if a URL stays live. This stack is destroyed after evidence capture (see *Cost and teardown*), so there is no lasting URL for a certificate to protect — the deliverable is a recording, not a link. Documented as a known gap with the one-line change to add it. |
| 3 | CloudWatch | **7-day retention + alarms** | Alarms are not decorative here — they are the blue/green rollback trigger (see #4). |
| 4 | Deploy strategy | **Blue/green via CodeDeploy, canary traffic shift, auto-rollback** | No recurring cost (CodeDeploy for ECS is free, second target group is free). Makes the alarms load-bearing. The strongest talking point in the project. Canary rather than all-at-once for the reason in *CodeDeploy* below — it is what makes "zero downtime" true rather than aspirational. |
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
                 └──────────┬───────────┘
                            │  :443 only, to endpoint_sg
              ┌─────────────▼──────────────┐
              │  VPC endpoints (no NAT,    │   ecr.api  ┐ interface
              │  no IGW route, no egress)  │   ecr.dkr  ┤ endpoints
              │                            │   logs     ┘
              └────────────────────────────┘   s3 ──── gateway (free)
```

Traffic never reaches a task except through the ALB. Tasks have no public IP,
no inbound path from the internet, **and no outbound route to it either** —
the private route tables contain no `0.0.0.0/0` entry at all. Everything the
task needs (pull the image, ship logs) is reached over PrivateLink inside the
VPC.

---

## Bootstrap (manual, once)

Remote state has to exist before Terraform can use it, so this is done by hand:

- **S3 bucket** for state — versioning on, SSE enabled, public access blocked.
- **State locking.** Terraform **1.16.0 is installed** (verified), so native S3
  locking via `use_lockfile = true` is available and **no DynamoDB table is
  needed** — one less resource than the original outline called for.
- Region: **us-east-1** (cheapest, and Fargate x86_64 is universally available).
- Tagging convention applied via provider `default_tags`: `Project`,
  `Environment`, `ManagedBy = terraform`.

`terraform` **v1.16.0 is installed** and `aws-cli` v2.36.19 is present.

---

## Terraform layout

```
infra/
├── versions.tf        # provider + backend config, pinned versions
├── variables.tf       # environment, region, sizing, repo name
├── network.tf         # VPC, subnets, IGW, route tables (no NAT)
├── endpoints.tf       # ECR api/dkr, S3 gateway, CloudWatch Logs
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

### Network — no NAT, no internet egress
- VPC `10.0.0.0/16`; 2 public + 2 private subnets across 2 AZs.
- **No NAT gateway and no `0.0.0.0/0` route in the private route tables.** The
  tasks cannot reach the internet, and nothing on the internet can initiate a
  connection to them. This is a stronger and more precise claim than "private
  subnets behind a NAT," and it is trivially demonstrable: show the route table.
- The application needs no outbound internet access — the model is baked into
  the image and it calls no external services — so nothing is given up.
- Four endpoints replace the NAT:

  | endpoint | type | why |
  |---|---|---|
  | `ecr.api` | interface | ECR authentication and metadata |
  | `ecr.dkr` | interface | the Docker registry protocol itself |
  | **`s3`** | **gateway** | **ECR image layers are stored in S3** |
  | `logs` | interface | CloudWatch Logs via the awslogs driver |

> **Trap:** the S3 gateway endpoint is the one everyone forgets. Without it,
> `ecr.api` and `ecr.dkr` succeed, authentication works, and then the image
> pull hangs and the task dies — because the layers themselves come from S3.
> It is free and attaches to the route table rather than a subnet, so it looks
> unlike the other three.

- Interface endpoints need their own security group: **`:443` inbound from
  `task_sg` only**. They also need `private_dns_enabled = true`, otherwise the
  AWS SDK keeps resolving the public endpoint names and the traffic has nowhere
  to go.
- *Verify at build time:* this endpoint set is what Fargate platform 1.4.0
  requires, where image pulls and log traffic traverse the task ENI. ECS
  control-plane traffic is handled by AWS outside the customer VPC and needs no
  endpoint of its own.
- **Cost honesty:** interface endpoints bill **per AZ**, so 3 endpoints × 2 AZs
  = 6 ENIs at ~$0.01/hr = **$0.06/hr**, against a single NAT's $0.045/hr. This
  is *more* expensive, not a wash — about +$11/mo. Data processing is cheaper
  ($0.01/GB vs $0.045/GB), which barely matters at this volume. The trade is
  ~$0.015/hr for removing internet egress entirely.

### Security groups — the "strict" claim
This is the specific detail worth being able to explain, so it gets built
precisely:

- `alb_sg`: ingress `:80` from `0.0.0.0/0`; egress to `task_sg` on `:8000`.
- `task_sg`: ingress `:8000` **from `alb_sg` by security-group ID**, never by
  CIDR; egress `:443` to `endpoint_sg` **and to the AWS-managed S3 prefix
  list** — not to `0.0.0.0/0`.

> **Trap, and a correction to this plan's own earlier wording.** "Egress to
> `endpoint_sg` only" is wrong, and wrong in a way that reproduces exactly the
> failure the S3 gateway endpoint was added to prevent. A gateway endpoint is a
> **route, not an ENI**: the packets still leave the task addressed to S3's
> public range, so they never match a rule scoped to the endpoint security
> group. Locking egress to `endpoint_sg` alone gives you successful ECR
> authentication followed by a hung layer pull — the same symptom as omitting
> the endpoint entirely, now caused by the security group. The fix is a second
> egress rule to the S3 managed prefix list, its id read off
> `aws_vpc_endpoint.s3.prefix_list_id` rather than hardcoded, since `pl-*`
> values are region-specific.
- `endpoint_sg`: ingress `:443` from `task_sg` only.
- No SSH anywhere. No `0.0.0.0/0` ingress on tasks. `assign_public_ip = false`.

Every rule in the mesh references another security group by ID. There is no
CIDR-based rule anywhere except the ALB's `:80` from the internet, which is the
one place it belongs.

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

> **Trap: the first apply has nothing to pull.** `image_tag` defaults to
> `bootstrap` against an empty, `IMMUTABLE` ECR repository, so a first
> `terraform apply` at `desired_count = 2` creates a service whose tasks can
> never pull an image. It churns failed task launches until the first workflow
> run pushes a real SHA — not fatal, but a confusing twenty minutes if it is
> hit unprepared. Apply with `desired_count = 0`, run the deploy workflow, then
> raise it.

### Autoscaling
- Target min 2, max 6.
- **CPU target tracking as the primary policy.** The plan originally favoured
  `ALBRequestCountPerTarget`, but that metric's `resource_label` must name a
  *specific* target group — and under blue/green the active target group swaps
  on every deploy. CPU avoids that whole class of breakage.
- Thresholds set from a **measured** per-task capacity on Fargate, not guessed.
  Local numbers (3,108 RPS containerized on an M1) will not transfer to
  0.5 vCPU; measuring it is a deliverable of this phase.
- **Autoscaling is invisible unless it is driven.** Configured-but-unexercised
  is the default outcome here and "did you ever actually see it scale?" is a
  guaranteed question. `scripts/benchmark.py` already points at the ALB, so
  holding enough load to breach the CPU target and capturing the scale-out is
  nearly free — it is on the evidence list for that reason.

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
- Traffic shift: **`CodeDeployDefault.ECSCanary10Percent5Minutes`**, with a short
  bake before blue tasks terminate.

> **Why not `AllAtOnce`.** All-at-once moves 100% of traffic to the replacement
> task set, and only *then* does the 5xx alarm need a full period (60s) to
> breach before the rollback begins. That is a real one-to-three minute outage,
> which directly contradicts the "zero downtime" claim this phase exists to
> prove. Under canary only 10% of requests reach a bad build, the alarm still
> fires on exactly the same signal, and the rollback claim is true rather than
> aspirational. The cost is a ~6-minute deployment instead of a ~1-minute one.
> `Linear10PercentEvery1Minutes` is the other realistic option and takes ten.

- `auto_rollback_configuration` on `DEPLOYMENT_FAILURE` **and** `DEPLOYMENT_STOP_ON_ALARM`.
- `blue_green_deployment_config` with `terminate_blue_instances_on_deployment_success`
  wait time so there is a real window to observe both task sets.
- `appspec.yaml` with a `<TASK_DEFINITION>` placeholder the workflow substitutes.

**The two rollback paths are not equivalent, and the demo has to pick one.**

| broken how | what CodeDeploy sees | what rolls it back |
|---|---|---|
| container will not start (bad CMD, missing model, wrong arch) | green tasks never pass the ALB health check on `/ready`, so **traffic never shifts** | `DEPLOYMENT_FAILURE` — the deployment times out |
| container starts, `/ready` returns 200, `/predict` returns 500 | green tasks look healthy, **traffic shifts**, then real requests fail | `DEPLOYMENT_STOP_ON_ALARM` — the 5xx alarm breaches |

The first case is the boring one: nothing bad ever reaches a user, but the
alarms and the `alarm_configuration` block are never touched — it demonstrates
that the load balancer refuses to promote a dead task set, not that the
rollback wiring works. **The headline demo is the second case**, because that
is the one that exercises the whole chain: alarm → CodeDeploy → traffic shifted
back to blue tasks that are still running and still warm.

**Both are driven from `workflow_dispatch`, neither needs a throwaway image.**
`simulate_failure` is a choice input — `none` | `startup` | `runtime` — and the
render step injects one environment override into the task definition:

| mode | override | path exercised |
|---|---|---|
| `startup` | `MODEL_PATH=/srv/models/does-not-exist.onnx` | `FraudModel.load` raises in the lifespan handler, the process exits, `/ready` never answers, traffic never shifts → `DEPLOYMENT_FAILURE` |
| `runtime` | `FAULT_INJECT_PREDICT=true` | container starts, `/ready` returns 200, task set is promoted, the canary shifts 10% of traffic onto it, *then* inference 500s → `DEPLOYMENT_STOP_ON_ALARM` |

> **Why a chaos hook rather than just more bad configuration.** No environment
> variable can produce the `runtime` shape on its own: model path, metadata path
> and the feature-count check are all validated inside `FraudModel.load`, so
> every misconfiguration kills the process at startup and collapses into the
> `startup` row. Producing a task that is *healthy and wrong* requires the
> application's cooperation. `FAULT_INJECT_PREDICT` (`app/config.py`) is that
> cooperation: default off, checked in `_predict` so it covers both inference
> routes, deliberately below `/health` and `/ready` so the task still passes its
> health check, and logged loudly at startup so a task running with it enabled
> is never a mystery. It is four lines, and it buys the only evidence in this
> phase that proves a mechanism rather than a configuration.

Remember the alarms need datapoints: run load through the ALB while the
`runtime` deployment is in flight, or nothing breaches and the broken build is
reported as a success.

### Observability
- Log group, **7-day retention** (default is never-expire, which quietly
  accrues cost).
- Alarms **wired into the CodeDeploy rollback trigger**, both on the
  `LoadBalancer` dimension rather than a target group — under blue/green the
  production target group alternates on every deployment, so a target-group
  alarm spends half its life watching the idle group. The load balancer is the
  one dimension whose meaning is stable across the swap. (Same reasoning that
  ruled out `ALBRequestCountPerTarget` for autoscaling.)
  - `HTTPCode_Target_5XX_Count` above threshold
  - `TargetResponseTime` p99 above threshold
- **`UnHealthyHostCount` is monitored but deliberately NOT wired to rollback** —
  a departure from this plan's first draft. `DEPLOYMENT_STOP_ON_ALARM` evaluates
  alarms *during* the deployment, and a blue/green deployment necessarily
  registers a fresh, not-yet-healthy task set into the standby group; those
  tasks are legitimately unhealthy for the ~45s ORT takes to load and two health
  checks to pass. Wiring it would fire on every deployment's own normal startup
  and roll back good releases — the alarm would be measuring the deployment
  rather than the application. The 5XX and latency alarms have no such coupling:
  they only ever see traffic that was actually routed. It stays as a per-target-
  group alarm at three evaluation periods, so sustained unhealthy hosts still
  page; they just do not get a veto over deployments.

> **No traffic, no alarm.** Both rollback alarms are
> `treat_missing_data = "notBreaching"` — they have to be, or an idle load
> balancer parks them in `INSUFFICIENT_DATA` and CodeDeploy refuses to start a
> deployment whose alarms it cannot evaluate. The consequence is that **an idle
> ALB emits no datapoints and neither alarm can ever breach**: a genuinely
> broken build deploys clean and CodeDeploy reports success. The rollback
> demonstration therefore requires load running through the ALB *for the
> duration of the deployment*, not before it.
- **ALB access logs to S3.** Pennies at this volume, and it answers the "how
  would you investigate a bad request after the fact" follow-up with a bucket
  rather than a shrug.
- **An AWS Budgets alarm.** Free, and it mitigates the risk this plan already
  names as the real one — leaving the stack standing, not running it.

> **Ordering dependency — the alarm thresholds are load-bearing.** The plan
> already says autoscaling thresholds must follow the Fargate measurement; the
> alarm thresholds are the same problem with higher stakes, because they gate
> every deployment. Set `alarm_p99_latency_seconds` or `alarm_5xx_threshold` too
> tight and every deploy rolls itself back, which reads as CodeDeploy being
> broken; set them too loose and the rollback demo never fires. Correct
> sequence: **apply → benchmark through the ALB → set thresholds from the
> measurement → then attempt the rollback demo.**

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

The workflow also accepts two `workflow_dispatch` inputs used only for
evidence capture: `image_tag`, to deploy something already in ECR instead of
building, and `simulate_failure` (`none` | `startup` | `runtime`), which injects
one environment override to exercise either rollback path — see *CodeDeploy*.

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
5. **Prove the rollback — recorded, not screenshotted.** Dispatch the deploy
   workflow with `simulate_failure: runtime` **while load is running through
   the ALB**, and show the canary shift,
   the 5xx alarm breaching, and CodeDeploy shifting traffic back to the still-warm
   blue task set with zero downtime. This is the single most valuable piece of
   evidence in the phase — it demonstrates the mechanism actually works rather
   than merely existing. **Capture it as a short screen recording or GIF**; a
   forty-second clip of traffic shifting back is worth more than any paragraph
   written about it, and it is the artifact that survives teardown. Run
   `simulate_failure: startup` too — it is one more dispatch and it shows the
   other rollback path, where traffic never shifts at all.
6. **Prove the autoscaling:** hold load through the ALB until the CPU target is
   breached and capture the scale-out from 2 tasks, then the scale-in.
7. Multi-AZ: tasks running in two AZs; kill one and show the ALB routing on.
8. CloudWatch logs and an alarm in OK state.
9. `terraform destroy`, and the AWS Budgets alarm confirming spend returned to
   zero.

---

## Cost and teardown

| item | ~hourly | ~monthly |
|---|---|---|
| ALB | $0.0225 | $16 |
| VPC interface endpoints (3 × 2 AZs) | $0.060 | $44 |
| S3 gateway endpoint | free | free |
| Fargate 2 × (0.5 vCPU / 1 GB) | $0.049 | $36 |
| ECR + CloudWatch | negligible | ~$1 |
| **total** | **~$0.13/hr** | **~$97/mo** |

The endpoint line is the price of having no internet egress; a single NAT would
be $0.045/hr instead, saving ~$11/mo and reintroducing a route to the internet.

Approximate, us-east-1. A few hours of evidence capture costs well under a
dollar; the risk is leaving it up, not running it.

```bash
terraform destroy    # documented in the README, not an afterthought
```

Keep the ECR images and the state bucket — both negligible. The ALB and the
interface endpoints are what accrue cost if the stack is left standing.

### The stack is destroyed; the artifact is the repository

At ~$97/mo this cannot be left running, so **there is deliberately no live demo
URL** — which is what settles the HTTPS decision above, and what makes the
evidence capture the actual deliverable rather than a formality. What ships:

- The **README**, with the architecture diagram, the security-group mesh, and the
  benchmark measured through the ALB alongside the local number.
- The **rollback recording** — the one piece of evidence that proves a mechanism
  rather than a configuration.
- The **Terraform**, which is a `terraform apply` away from standing the whole
  thing up again. "It is destroyed because it costs $97/mo, here is the plan
  output and the recording" is a better answer than a link to a running toy,
  and it is the honest one.

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
5. **A missing or misconfigured VPC endpoint** produces tasks that hang on
   launch and die, with an error that does not name the cause. The two usual
   culprits are the forgotten S3 gateway endpoint (image layers) and
   `private_dns_enabled = false` (names still resolve to public IPs).
6. **Fargate capacity is unmeasured.** Autoscaling *and alarm* thresholds must
   follow the measurement, not precede it — the alarm ones gate every
   deployment.
7. **The first apply has no image to pull** (see the bootstrap trap above).
   Costs twenty confusing minutes, not correctness.
8. **Task egress scoped to `endpoint_sg` alone** silently reintroduces the hung
   image pull, because the S3 gateway endpoint is a route rather than an ENI.
   The S3 prefix-list egress rule is not optional.
9. **A rollback demo against an idle load balancer proves nothing** — with
   `notBreaching` on both alarms, no traffic means no datapoints means no
   breach, and the broken deployment is reported as a success.

---

## Open sub-decisions — resolved

- **Endpoints in 1 AZ vs 2** — **2**, matching the AZ spread. One halves the
  endpoint cost to $0.03/hr but makes task launches in the other AZ depend on a
  single AZ's endpoint ENIs, which quietly undercuts the multi-AZ claim.
- **Region** — **`us-east-1`**.
- **Traffic shift config** — **canary**, resolved under *CodeDeploy* above.
- **Container Insights** — **off.** Roughly $2–3/mo for metrics that will not be
  looked at; the log group and the three alarms already carry the observability
  story.
