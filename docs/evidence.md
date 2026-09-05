# Phase 3 — evidence log

What was actually run against AWS account `589158200888` in `us-east-1`, with the
output it produced. The stack is destroyed after capture, so **this file and the
Terraform are the artifact** — everything below was reproducible from
[the runbook](../README.md#the-evidence-runbook) at the time of writing, and
where the runbook was wrong, this log says so.

Raw captures live in [`evidence/`](evidence/).

---

## A · Stand it up

```bash
export AWS_REGION=us-east-1
./scripts/bootstrap-state.sh
terraform -chdir=infra init -backend-config=backend.hcl
terraform -chdir=infra apply -var-file=envs/prod.tfvars \
  -var bootstrap=true -var budget_notification_email=<address>
gh variable set AWS_DEPLOY_ROLE_ARN \
  --body "$(terraform -chdir=infra output -raw github_actions_role_arn)"
gh workflow run deploy.yml --ref main
terraform -chdir=infra apply -var-file=envs/prod.tfvars \
  -var budget_notification_email=<address>
```

**Result:** 59 resources on the bootstrap apply, 2 more (autoscaling target and
policy) on the second. Service reached `runningCount: 2` about 25 seconds after
the second apply.

```
$ curl -s http://fraud-api-prod-1157734690.us-east-1.elb.amazonaws.com/ready
{"status":"ready","model_loaded":true,"threshold":0.7564894556999207}

$ curl -s -X POST .../predict -H 'content-type: application/json' -d @payload.json
{"fraud_probability":0.9996738433837891,"is_fraud":true,"threshold_used":0.7564894556999207}
```

That probability is the same fixture row the ONNX parity tests use, so the model
serving on Fargate agrees with the one trained locally, end to end through the
load balancer.

### Two things that did not go to plan

**CodeDeploy is unavailable on this account.** `CreateApplication` — and even a
read-only `ListApplications` — return `SubscriptionRequiredException`, while
CodeBuild, SNS, Lambda, CloudFormation, CodePipeline and Application Auto
Scaling all work. The stack was migrated to ECS-native canary deployments;
see the [README](../README.md#blue-green-deployments-with-automatic-rollback).

**The OIDC trust policy matched nothing**, failing with a bare
`Not authorized to perform sts:AssumeRoleWithWebIdentity`. GitHub issues an
immutable subject carrying numeric owner and repository IDs. The received value
is visible only in CloudTrail:

```
$ aws cloudtrail lookup-events --region us-east-1 \
    --lookup-attributes AttributeKey=EventName,AttributeValue=AssumeRoleWithWebIdentity

sub: repo:JWanderer73@184721915/credit-card-fraud@1356551646:ref:refs/heads/main
     ^^^^^^^^^^^^^^^^^^^^^^^^^ ^^^^^^^^^^^^^^^^^^^^^^^^^^^^
documented form: repo:JWanderer73/credit-card-fraud:ref:refs/heads/main
```

---

## B · Security evidence

```bash
./scripts/verify-deployment.sh
```

Full output: [`evidence/b-verify-deployment.txt`](evidence/b-verify-deployment.txt).
All checks passed. The two load-bearing extracts:

**No route to the internet.** Both private route tables, in full:

```
Destination    PrefixList     Target
10.0.0.0/16    -              local
-              pl-63a5400a    vpce-08b377ef28ad3c65d
```

Two routes. Local VPC traffic, and S3 via the gateway endpoint. No `0.0.0.0/0`
entry of any kind, and `describe-nat-gateways` returns zero — while the tasks
are still pulling images and shipping logs.

**Reachable only through the ALB.** The task security group's rules:

```
ingress  :8000  <- sg-07fccc93cde938d43  (the ALB)      no CIDR anywhere
egress   :443   -> sg-03e009c7498fa37cb  (VPC endpoints)
egress   :443   -> pl-63a5400a           (S3 prefix list, image layers)
```

That last rule is the one the plan's first draft got wrong. A gateway endpoint
is a route, not an ENI, so its traffic is not covered by the egress rule to the
endpoint security group — locking egress down to `endpoint_sg` alone reproduces
the exact hung-image-pull the S3 endpoint exists to prevent.

Tasks in `us-east-1a` and `us-east-1b`, both `HEALTHY`, neither ENI carrying a
public IP, and a direct connection to `10.0.151.197:8000` from outside the VPC
times out.

### Multi-AZ failover

Placement is one claim; surviving the loss of an AZ is another. Autoscaling was
still suspended, which makes this cleaner rather than harder — suspension stops
Application Auto Scaling from changing `desiredCount`, but not the ECS *service
scheduler*, so the replacement is unambiguously the scheduler maintaining
capacity rather than a scaling activity.

```bash
# sampling POST /predict every second throughout
aws ecs stop-task --cluster fraud-api-prod \
  --task e5daef06929c4519893a03c660440664 \
  --reason "multi-AZ failover evidence"
```

```
18:32:36  stop-task issued            -> DEACTIVATING
18:32:53  replacement PROVISIONING in us-east-1a   (us-east-1b serving alone)
18:33:09  ACTIVATING
18:33:42  RUNNING
18:33:59  HEALTHY                     -> 83 seconds end to end
```

**240 requests over four minutes. 240 x 200. Zero failures**
([capture](evidence/b-failover-traffic.txt) ·
[task states](evidence/b-failover-events.txt)).

Half the fleet was destroyed and an entire availability zone went empty for
about 80 seconds without a single client-visible error.

`deregistration_delay = 30` is what makes that true. On the AWS default of 300
seconds the stopped task sits draining for five minutes while the target group
slowly stops routing to it, and in-flight requests during that window can fail.
The setting was chosen to keep deployments from crawling; this is the second
thing it buys.

---

## C · Per-task capacity, measured through the ALB

Autoscaling suspended first, so a scale-out could not move the denominator:

```bash
terraform -chdir=infra apply -var-file=envs/prod.tfvars \
  -var budget_notification_email=<address> -var suspend_autoscaling=true

for C in 2 4 8 16 32 64; do
  python scripts/benchmark.py --url "http://$ALB" --mode single \
    --processes 4 --concurrency $C --duration 60 --warmup 5
done
```

The CPU column came from this — the same metric target tracking consumes,
published per-service without Container Insights:

```bash
aws cloudwatch get-metric-statistics --namespace AWS/ECS \
  --metric-name CPUUtilization \
  --dimensions Name=ClusterName,Value=fraud-api-prod \
               Name=ServiceName,Value=fraud-api-prod \
  --start-time "$(date -u -v-40M '+%Y-%m-%dT%H:%M:%SZ')" \
  --end-time "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
  --period 60 --statistics Average Maximum --output table
```

2 tasks x 0.5 vCPU, CPU as 1-minute average.

> **The CPU column below is wrong and is kept for the record.** These runs were
> 60 seconds; `AWS/ECS CPUUtilization` is a one-minute average and had not
> settled. Sustained load at the same concurrency reached ~95%, not ~66% — see
> [step F](#this-step-invalidated-step-cs-cpu-column). The RPS and latency
> columns are unaffected.

| in flight | RPS | p50 | p95 | p99 | CPU (understated) |
|---|---|---|---|---|---|
| 8 | 102 | 77 ms | 84 ms | 98 ms | ~3% |
| 16 | 207 | 76 ms | 83 ms | 106 ms | ~3% |
| 32 | 413 | 76 ms | 84 ms | 113 ms | ~13% |
| 64 | 815 | 76 ms | 87 ms | 141 ms | ~35% |
| **128** | **1,309** | 86 ms | 145 ms | 306 ms | **~66%** |
| 256 | 418 | 222 ms | 2,262 ms | 3,692 ms | ~94-100% |

**The first three rows measure the network, not the service.** Throughput
doubles exactly with concurrency while p50 stays pinned at ~76 ms — latency that
will not degrade under 4x the load means nothing is queueing. Little's Law
closes it: `32 / 0.0765 s = 418` against 413 measured. The ~76 ms is round-trip
to Virginia, against 6.7 ms p99 on loopback locally.

Real saturation appears at 128 in flight: **1,309 predictions/sec, p99 306 ms**,
on 1.0 vCPU total. At 256 it does not degrade, it collapses — throughput falls
to a third while p99 reaches 3.7 s.

Against the local 4,120/s on an M1: ~1,300 RPS per vCPU here versus ~2,000 per
core locally. Same order, so ONNX Runtime is behaving consistently; the gap is
core count and clock, not the deployment.

---

## D · Thresholds set from the measurement

```bash
# edit cpu_target_utilization / alarm_* in infra/envs/prod.tfvars, then
terraform -chdir=infra apply -var-file=envs/prod.tfvars \
  -var budget_notification_email=<address> -var suspend_autoscaling=true
```

The relationship is ~20 RPS per 1% CPU, so 100% is roughly 2,000 RPS across the
pair.

| setting | value | why |
|---|---|---|
| `cpu_target_utilization` | 50 | The cliff between 66% and 94% is one doubling of load, and scale-out needs ~3 min of sustained breach plus ~1 min of task start. 50% (~1,000 RPS) leaves 2x margin for that reaction time; 60% leaves 1.5x. |
| `alarm_p99_latency_seconds` | 1.0 | Healthy p99 spanned 98-306 ms at every load level; the only excursion was collapse at 3.7 s. 1.0 s sits ~3x above the worst healthy reading and ~4x below collapse. |
| `alarm_5xx_threshold` | 10 | Zero 5XX across ~190,000 requests, *including at collapse* — the service queues rather than erroring. Any 5XX is anomalous. |

---

## E · Rollback — the alarm to traffic-shift chain

```bash
# load first, and leave it running
python scripts/benchmark.py --url "http://$ALB" --mode single \
  --processes 2 --concurrency 2 --duration 900

# NOTE the image_tag. ECR is IMMUTABLE, so rebuilding an unchanged commit is
# rejected on push and the demo dies before it starts. Passing the tag also
# isolates the variable: identical bytes, one environment override different.
gh workflow run deploy.yml \
  -f image_tag=e9cbcfe6b20fa06382376253f2097c02914b08ba \
  -f simulate_failure=runtime
```

### Timeline

```
17:56:42   canary begins routing -- first 500
17:57-17:59  steady ~15% of requests failing
18:00:02   HTTPCode_Target_5XX_Count alarm -> ALARM
18:00:23   ECS rolls back; PRIMARY returns to revision 3
18:00:30   last 500
18:02:32   broken task set fully drained
```

ECS, in its own events:

```
(service fraud-api-prod) (deployment ecs-svc/8028...) deployment failed: alarm detected.
(service fraud-api-prod) rolling back to deployment ecs-svc/3225...
(service fraud-api-prod) has stopped 2 running tasks
(service fraud-api-prod) has reached a steady state.
```

### Impact, from two independent clients

| client | requests | failed | success |
|---|---|---|---|
| curl loop, 1/sec ([capture](evidence/e-rollback-traffic.txt)) | 900 | 27 | 96.9% |
| benchmark, 49.8 RPS ([summary](evidence/e-rollback-load.txt)) | 44,778 | 1,343 | 97.0% |

A completely broken build was deployed to production and **~97% of requests
succeeded anyway**, with no human intervention.

### The number that justifies the canary

The alarm took **3m20s** to fire, not the 60 seconds the configuration implies.
Threshold 10, one evaluation period, and ~300 5XX per minute arriving — the
threshold was blown past almost immediately. The delay is CloudWatch ALB metric
publication latency, and it is not tunable.

That is the argument for canary with a measured cost rather than a hypothesis.
About 190 requests passed through the 3m48s degraded window; 27 of them failed.
Under `BLUE_GREEN` — ECS's all-at-once variant — **all ~190 would have failed**,
because 100% of traffic moves the moment the replacement goes healthy and *then*
you wait out the same unavoidable metric latency.

So the `CANARY` vs `BLUE_GREEN` distinction is not naming pedantry. It is the
difference between 14% and 100% of requests failing, for the same three minutes.

---

## E · The other rollback shape — and the gap it exposed

```bash
gh workflow run deploy.yml \
  -f image_tag=e9cbcfe6b20fa06382376253f2097c02914b08ba \
  -f simulate_failure=startup
```

> **Pass a tag that is actually in ECR.** `$(git rev-parse HEAD)` is wrong if
> HEAD has moved to a commit CI never built — the deployment then fails with
> `CannotPullContainerError ... not found`, which is a different failure shape
> than the one being tested. Check with
> `aws ecr describe-images --repository-name fraud-api-prod --query 'imageDetails[].imageTags[]'`.

`simulate_failure=startup` injects `MODEL_PATH=/srv/models/does-not-exist.onnx`.
`FraudModel.load` raises in the lifespan handler, the process exits, `/ready`
never answers, and the replacement task set never passes its health check.

ECS behaved exactly as intended on the traffic side:

```
(task d977478a...) (port 8000) is unhealthy in (target-group ...-blue)
                   due to (reason Health checks failed)
```

Production never wavered — `/ready` returned 200 on every sample throughout.
Traffic is never routed to a task set that never goes healthy, so this failure
shape cannot reach a user.

### But it never recovered

```
01:50:33  deployment started
02:19:29  ##[error]{"state":"TIMEOUT","reason":"Waiter has timed out"}
```

**29 minutes, and ECS was still retrying.** Broken task starts, fails its health
check, gets killed, gets retried, forever. Nothing ended it but the deploy
workflow's waiter giving up — and a failed workflow does not stop the ECS
deployment.

The cause is structural, not a misconfiguration. **Both rollback alarms sit on
the `LoadBalancer` dimension, so they only ever observe traffic that was
actually routed.** A task set that never goes healthy receives none, so the
alarms stay `OK` indefinitely while the deployment churns. The alarm mechanism
that recovers the `runtime` failure in 3m20s is blind to this one by
construction.

The README had claimed this path "rolls back on deployment failure". That was
inherited from the CodeDeploy design, which had a deployment timeout, and was
carried across the migration without re-verification. It was wrong.

### Aborting a stuck deployment

A deployment that will never converge has to be stopped by hand. Cancelling the
workflow does nothing to ECS:

```bash
ARN=$(aws ecs list-service-deployments --cluster fraud-api-prod \
        --service fraud-api-prod --query 'serviceDeployments[0].serviceDeploymentArn' \
        --output text)
aws ecs stop-service-deployment --service-deployment-arn "$ARN" --stop-type ROLLBACK
```

Returned the service to revision 3 at 2/2 tasks in about 45 seconds. Worth
knowing this lever exists before needing it at 3am.

### The fix, and the confirmation

```bash
# after adding deployment_circuit_breaker to infra/ecs.tf
terraform -chdir=infra apply -var-file=envs/prod.tfvars \
  -var budget_notification_email=<address> -var suspend_autoscaling=true

# confirm it coexists with the canary strategy
aws ecs describe-services --cluster fraud-api-prod --services fraud-api-prod \
  --query 'services[0].deploymentConfiguration'
```

```hcl
deployment_circuit_breaker {
  enable   = true
  rollback = true
}
```

The circuit breaker watches **consecutive task-launch failures** rather than
traffic — the only signal available when no traffic exists. AWS fills in
`resetOnHealthyTask: true`, so transient flakiness does not trip it; only
sustained inability to launch does.

Re-running the identical failure with it enabled
([capture](evidence/e-startup-circuitbreaker.txt)):

```
20:12:xx  deployment started
20:19:53  PRIMARY back to revision 3, broken revision 7 -> FAILED

(service fraud-api-prod) deployment failed: tasks failed to start.
(service fraud-api-prod) rolling back to deployment ecs-svc/3225...
```

**8 minutes to automatic recovery, against 29+ and counting.** `prod=200` on
every sample of both runs.

### Two mechanisms, two blind spots

| failure shape | detected by | signal | recovery |
|---|---|---|---|
| starts, serves errors | 5XX alarm | traffic that *was* routed | 3m20s |
| never starts | circuit breaker | task launches that failed | 8m |

Neither is redundant. The alarms cannot see a task set that receives no traffic;
the circuit breaker cannot see a task that is healthy but wrong. Only running
both failure shapes against the real thing showed that the second one was
uncovered.

---

## The healthy path, for contrast

Captured during an ordinary deployment of a good build (commit `e9cbcfe`),
sampling `POST /predict` every 4 seconds:

```
150 requests over 10m36s
150 x 200
  0 x anything else
```

[Traffic capture](evidence/healthy-canary-traffic.txt) ·
[task set samples](evidence/healthy-canary-taskssets.txt)

The task set samples are the concrete form of "both sets alive": for the full
ten minutes ECS reported

```
PRIMARY   task-definition/fraud-api-prod:3   running=2   IN_PROGRESS
ACTIVE    task-definition/fraud-api-prod:2   running=2   COMPLETED
```

Four tasks running at once — the replacement and the original. That is why a
rollback is a traffic shift onto tasks that are already warm rather than a fresh
deployment: you can see the warm set sitting there.

It also shows the canary working. `BLUE_GREEN` would have moved 100% the moment
revision 3 went healthy, roughly nine minutes earlier.

---

## F · Autoscaling, actually scaling

Autoscaling resumed first, then sustained load at 128 in flight — the level step
C identified as the knee, chosen so the service is pushed well past the 50%
setpoint without tipping into the collapse regime measured at 256.

```bash
terraform -chdir=infra apply -var-file=envs/prod.tfvars \
  -var budget_notification_email=<address>          # resume scaling

python scripts/benchmark.py --url "http://$ALB" --mode single \
  --processes 4 --concurrency 32 --duration 780 --warmup 5

aws application-autoscaling describe-scaling-activities --service-namespace ecs \
  --query 'ScalingActivities[:4].{T:StartTime,Cause:Cause,Status:StatusCode}'
```

```
20:52  2/2   cpu  3%    baseline
20:54  2/2   cpu 96%    load saturating
20:57  4/2   cpu 93%    <- scale-out #1  (+5m)
20:58  4/4   cpu 42%    capacity landed
21:03  6/4   cpu 61%    <- scale-out #2  (+11m)
21:04  6/6   cpu 69%    ceiling reached, max_capacity = 6
21:07  6/6   cpu  3%    load ends
```

**1,065,468 requests. Zero errors. 1,365 RPS, p50 78 ms, p99 354 ms** —
including the stretch at 95% CPU
([timeline](evidence/f-scaleout.txt) · [load summary](evidence/f-scaleout-load.txt)).

Application Auto Scaling attributes both actions to
`TargetTracking-service/fraud-api-prod/fraud-api-prod-AlarmHigh`, so the setpoint
from step D is demonstrably what drove them. End-to-end scale-out latency was
**~5 minutes**: three minutes of sustained breach for the target-tracking alarm,
then task start and health checks.

### This step invalidated step C's CPU column

At 128 in flight, step C recorded **~66% CPU**. Sustained load at the *identical*
concurrency reached **~95%**.

`AWS/ECS CPUUtilization` is a one-minute average that lags the load producing it,
and the step C runs were 60 seconds — they ended before the metric settled. The
short runs were deliberate, so that a scale-out could not fire mid-measurement.
That was the right call for the throughput numbers and the wrong one for CPU,
and the conflict went unnoticed until this step contradicted it.

Corrected: **~14 RPS per 1% CPU**, and 100% is roughly 1,400 RPS across the pair
rather than 2,000. The 50% setpoint survives the correction — ~700 RPS still
leaves nearly 2x headroom to collapse — but the published justification for it
had been arithmetic on bad inputs.

The lesson generalises: **a metric with an averaging window cannot be measured by
a run shorter than that window.** Throughput stabilises in seconds; a 1-minute
average does not.

### Why it went straight to the ceiling

CPU did not fall proportionally after scaling — 42-73% at 4 tasks, 56-69% at 6 —
so the service climbed to `max_capacity` rather than settling.

That is an artefact of **closed-loop load**. With a fixed 128 requests in flight,
adding capacity does not reduce CPU; it raises throughput, because the clients
simply go faster. Real traffic is open-loop — arrival rate is set by users, not
by how quickly they are answered — and would have settled at 3-4 tasks.

Worth stating plainly, because "it scaled to max" reads like an over-aggressive
setpoint when it is really a property of the load generator.

### Scale-in

Deliberately not waited out: target tracking scales in only after **15
consecutive minutes** below target, with a 300-second cooldown between actions.
That asymmetry is intentional — capacity is added readily and removed
reluctantly, because shedding too eagerly turns a traffic dip into a cold-start
storm when it returns. It is also why this step runs last: every earlier step
wanted a clean 2-task baseline, and reaching one from 6 tasks costs a quarter of
an hour.

---

## Appendix: every successful command, in execution order

The sections above are organised by step. This is the flat chronological list —
what was actually run, in the order it was run, including the recoveries. Failed
attempts are noted where they explain the command that follows.

```bash
export AWS_REGION=us-east-1                       # CLI default is us-west-2

# --- bootstrap -----------------------------------------------------------
./scripts/bootstrap-state.sh
terraform -chdir=infra init -backend-config=backend.hcl
terraform -chdir=infra plan  -var-file=envs/prod.tfvars -var bootstrap=true -out=tfplan
terraform -chdir=infra apply tfplan
#   ^ FAILED at aws_codedeploy_app: SubscriptionRequiredException.
#     55 of 59 resources created. Diagnosis:
aws deploy list-applications                      # also SubscriptionRequired
aws codebuild list-projects                       # OK -- so CodeDeploy alone

# --- migrate to ECS-native (code change, see git log) ---------------------
terraform -chdir=infra apply tfplan
#   ^ FAILED: "advancedConfiguration field is required for all loadBalancers"
#     caused by ignore_changes = [load_balancer] suppressing it. Fixed in ecs.tf.
terraform -chdir=infra apply tfplan
aws ecs describe-services --cluster fraud-api-prod --services fraud-api-prod \
  --query 'services[0].deploymentConfiguration'
#   ^ revealed canaryConfiguration was silently dropped under BLUE_GREEN
aws ecs update-service --cluster fraud-api-prod --service fraud-api-prod \
  --deployment-configuration 'strategy=CANARY,bakeTimeInMinutes=5,canaryConfiguration={canaryPercent=10,canaryBakeTimeInMinutes=5}'
terraform -chdir=infra apply -var-file=envs/prod.tfvars -var bootstrap=true

# --- first deployment ----------------------------------------------------
gh variable set AWS_DEPLOY_ROLE_ARN \
  --body "$(terraform -chdir=infra output -raw github_actions_role_arn)"
git push origin main                              # CI -> Deploy
#   ^ Deploy FAILED: Not authorized to perform sts:AssumeRoleWithWebIdentity
aws cloudtrail lookup-events \
  --lookup-attributes AttributeKey=EventName,AttributeValue=AssumeRoleWithWebIdentity
#   ^ revealed the immutable subject format. Fixed in iam.tf.
terraform -chdir=infra apply -var-file=envs/prod.tfvars -var bootstrap=true
gh workflow run deploy.yml --ref main
terraform -chdir=infra apply -var-file=envs/prod.tfvars   # autoscaling -> 2 tasks
curl -s "http://$ALB/ready"

# --- B: security evidence ------------------------------------------------
./scripts/verify-deployment.sh
aws ecs stop-task --cluster fraud-api-prod --task <one task> \
  --reason "multi-AZ failover evidence"

# --- C/D: capacity and thresholds ----------------------------------------
terraform -chdir=infra apply -var-file=envs/prod.tfvars -var suspend_autoscaling=true
for C in 2 4 8 16 32 64; do
  python scripts/benchmark.py --url "http://$ALB" --mode single \
    --processes 4 --concurrency $C --duration 60 --warmup 5
done
aws cloudwatch get-metric-statistics --namespace AWS/ECS --metric-name CPUUtilization \
  --dimensions Name=ClusterName,Value=fraud-api-prod Name=ServiceName,Value=fraud-api-prod \
  --period 60 --statistics Average Maximum
# edit cpu_target_utilization / alarm_* in envs/prod.tfvars
terraform -chdir=infra apply -var-file=envs/prod.tfvars -var suspend_autoscaling=true

# --- E: rollback, runtime shape ------------------------------------------
python scripts/benchmark.py --url "http://$ALB" --mode single \
  --processes 2 --concurrency 2 --duration 900 &
gh workflow run deploy.yml -f image_tag=<tag in ECR> -f simulate_failure=runtime

# --- E: rollback, startup shape ------------------------------------------
gh workflow run deploy.yml -f image_tag=<tag in ECR> -f simulate_failure=startup
#   ^ first attempt passed $(git rev-parse HEAD), an unpushed commit CI never
#     built -> CannotPullContainerError. Wrong failure shape; aborted:
aws ecs stop-service-deployment --stop-type ROLLBACK \
  --service-deployment-arn "$(aws ecs list-service-deployments \
      --cluster fraud-api-prod --service fraud-api-prod \
      --query 'serviceDeployments[0].serviceDeploymentArn' --output text)"
#   ^ second attempt used the right tag and churned for 29 min without
#     recovering -- the alarms cannot see an unrouted task set. Added
#     deployment_circuit_breaker to ecs.tf, then:
terraform -chdir=infra apply -var-file=envs/prod.tfvars -var suspend_autoscaling=true
gh workflow run deploy.yml -f image_tag=<tag in ECR> -f simulate_failure=startup
#   ^ rolled back automatically in 8 minutes

# --- F: autoscaling ------------------------------------------------------
terraform -chdir=infra apply -var-file=envs/prod.tfvars        # resume scaling
python scripts/benchmark.py --url "http://$ALB" --mode single \
  --processes 4 --concurrency 32 --duration 780 --warmup 5
aws application-autoscaling describe-scaling-activities --service-namespace ecs
```

Every `apply` above also carried `-var budget_notification_email=<address>`,
omitted here for width. Leaving it off any single apply silently drops the
budget notification — Terraform has no memory of a `-var` between runs.

---

## Still outstanding

- `terraform destroy`, and the budget confirming spend returned to zero
