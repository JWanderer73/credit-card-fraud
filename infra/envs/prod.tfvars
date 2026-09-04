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

# Placeholder. Replace with a value derived from the Fargate benchmark -- see
# "Measuring per-task capacity" in the README.
cpu_target_utilization = 60

log_retention_days = 7
container_insights = false

# Canary, not all-at-once. All-at-once puts 100% of traffic on a bad build and
# only then waits a full alarm period to notice -- a real outage, which is the
# opposite of what this stack exists to demonstrate. Canary exposes 10% for five
# minutes on the same alarm signal. A deployment takes ~6 minutes instead of ~1.
deployment_config_name        = "CodeDeployDefault.ECSCanary10Percent5Minutes"
blue_termination_wait_minutes = 5

# Closed. Set to ["<your.ip>/32"] to curl the green task set during the bake
# window; CodeDeploy itself does not need this open.
test_listener_allowed_cidrs = []

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
