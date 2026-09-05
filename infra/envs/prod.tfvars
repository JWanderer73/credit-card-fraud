# Production stack.
#
# Every value here is also the module default -- this file exists so that a
# second environment is `-var-file=envs/<name>.tfvars` plus a second state key
# rather than a refactor, and so the settings that matter are visible in one
# place instead of scattered through variables.tf.

project     = "fraud-api"
environment = "prod"
aws_region  = "us-east-1"

# 2 AZs is the minimum for the availability claim. Interface endpoints bill per
# AZ, so this is also the dominant lever on the stack's hourly cost.
az_count = 2

# 0.5 vCPU / 1 GB.
task_cpu    = 512
task_memory = 1024

desired_count = 2
min_capacity  = 2
max_capacity  = 6

# MEASURED, not guessed -- and then corrected once the measurement itself was
# shown to be wrong.
#
# First pass, 60-second runs through the ALB at 2 tasks x 0.5 vCPU:
#
#   in flight    RPS     p50     p99      ECS CPUUtilization
#   -------------------------------------------------------
#          64     815    76ms   141ms     ~35%
#         128   1,309    86ms   306ms     ~66%
#         256     418*  222ms  3,692ms    ~94-100%   * collapsed
#
# Those CPU figures are TOO LOW. AWS/ECS CPUUtilization is a 1-minute average
# and lags the load that produces it, so a 60-second run ends before the metric
# settles. Sustained load at 128 in flight -- identical to the row above --
# reached ~95%, not 66%. Corrected, the ratio is ~14 RPS per 1% CPU and 100% is
# roughly 1,400 RPS across the pair, not 2,000.
#
# 50% survives the correction: ~700 RPS, which still leaves nearly 2x headroom
# to the collapse regime, and scale-out needs ~5 minutes end to end (3 minutes
# of sustained breach for the target-tracking alarm, plus task start) before new
# capacity lands. Verified under sustained load: 2 -> 4 tasks at +5m, 4 -> 6 at
# +11m, 1,065,468 requests, zero errors. See docs/evidence.md.
cpu_target_utilization = 50

log_retention_days = 7
container_insights = false

# ECS-native blue/green. Canary, not all-at-once: all-at-once puts 100% of
# traffic on a bad build and only then waits a full alarm period to notice --
# a real outage, which is the opposite of what this stack exists to demonstrate.
# 10% for five minutes reaches the same alarm on a tenth of the blast radius.
# A deployment takes ~11 minutes end to end, most of it deliberate waiting.
# CANARY, not BLUE_GREEN: in ECS's vocabulary BLUE_GREEN is the all-at-once
# variant and CANARY is the one that shifts 10% first. Same machinery.
deployment_strategy         = "CANARY"
canary_percent              = 10
canary_bake_time_in_minutes = 5
bake_time_in_minutes        = 5

# Closed. Set to ["<your.ip>/32"] to curl the green task set during the bake
# window; CodeDeploy itself does not need this open.
test_listener_allowed_cidrs = []

# Also measured. Healthy p99 ranged 98-306ms across every load level; the only
# time it left that band was congestive collapse at 3.7s. 1.0s sits ~3x above
# the worst healthy reading and ~4x below collapse, so it distinguishes the two
# without firing on normal traffic.
alarm_p99_latency_seconds = 1.0

# Zero 5XX responses across ~190,000 requests, including at collapse -- the
# service queues rather than erroring. Any 5XX is therefore anomalous, and 10
# in a minute is a floor that only a genuinely broken build reaches.
alarm_5xx_threshold = 10

github_repo   = "JWanderer73/credit-card-fraud"
github_branch = "main"

# ALB access logs: the only per-request record that outlives a rolled-back task
# set. Application logs go when the task set does.
enable_alb_access_logs    = true
access_log_retention_days = 7

# The real risk in this phase is leaving the stack standing, not running it.
# Set budget_notification_email on the command line or in a local override --
# an address committed to a public repository is a mailing list waiting to
# happen:
#
#   terraform apply -var-file=envs/prod.tfvars -var budget_notification_email=you@example.com
monthly_budget_usd = 20
