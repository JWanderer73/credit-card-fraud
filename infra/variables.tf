# ---------------------------------------------------------------------------
# Inputs.
#
# `environment` is what makes this a parameterized root module rather than a
# hard-coded one: a second stack is `-var-file=envs/staging.tfvars` plus a
# second state key, not a refactor. See the note in phase3-plan.md on why this
# is a flat root module and not modules/.
# ---------------------------------------------------------------------------

variable "project" {
  description = "Short name used as the prefix for every resource name."
  type        = string
  default     = "fraud-api"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,20}$", var.project))
    error_message = "project must be lowercase alphanumeric/hyphen, 2-21 chars (ALB and target-group names cap at 32)."
  }
}

variable "environment" {
  description = "Environment name. Part of every resource name and of the state key."
  type        = string
  default     = "prod"

  validation {
    condition     = can(regex("^[a-z0-9]{2,10}$", var.environment))
    error_message = "environment must be 2-10 lowercase alphanumeric characters."
  }
}

variable "aws_region" {
  description = "Region to deploy into."
  type        = string
  default     = "us-east-1"
}

variable "az_count" {
  description = <<-EOT
    Number of availability zones. 2 is the minimum for the "highly available"
    claim and is what the interface-endpoint cost estimate assumes (endpoints
    bill per AZ). Raising this raises endpoint cost linearly.
  EOT
  type        = number
  default     = 2

  validation {
    condition     = var.az_count >= 2 && var.az_count <= 3
    error_message = "az_count must be 2 or 3; an ALB requires at least two subnets."
  }
}

variable "vpc_cidr" {
  description = "CIDR for the VPC."
  type        = string
  default     = "10.0.0.0/16"
}

# --- Application ------------------------------------------------------------

variable "container_port" {
  description = "Port uvicorn listens on inside the container. Matches the Dockerfile's EXPOSE."
  type        = number
  default     = 8000
}

variable "container_name" {
  description = "Container name. CodeDeploy's appspec references this by name, so it must match .aws/appspec.yaml."
  type        = string
  default     = "fraud-api"
}

variable "image_tag" {
  description = <<-EOT
    Image tag for the task definition Terraform registers. Terraform only ever
    creates the FIRST revision; CodeDeploy owns the service's task definition
    thereafter and the deploy workflow registers git-SHA-tagged revisions. The
    default bootstraps the stack before any image exists.
  EOT
  type        = string
  default     = "bootstrap"
}

variable "task_cpu" {
  description = "Fargate task CPU units. 512 = 0.5 vCPU."
  type        = number
  default     = 512
}

variable "task_memory" {
  description = "Fargate task memory in MiB. Must be a valid pairing with task_cpu."
  type        = number
  default     = 1024
}

variable "uvicorn_workers" {
  description = <<-EOT
    Value of WORKERS in the container. At 0.5 vCPU there is half a core to go
    round, so 2 workers is already oversubscribed; ORT's intra-op pool is
    pinned to 1 thread (app/config.py) precisely so the workers do not fight
    each other for it.
  EOT
  type        = number
  default     = 2
}

# --- Service sizing and scaling --------------------------------------------

variable "bootstrap" {
  description = <<-EOT
    First apply, before any image exists.

    image_tag defaults to `bootstrap` against an empty, IMMUTABLE ECR
    repository, so a normal first apply creates a service whose tasks can never
    pull an image: it churns failed task launches until the first workflow run
    pushes a real SHA. Not fatal, but a confusing twenty minutes if it is hit
    unprepared.

    With this set, the service starts at zero tasks and no autoscaling target
    is created. Sequence:

      terraform apply -var bootstrap=true   # empty service, nothing to pull
      gh workflow run deploy.yml            # builds, pushes, deploys a real SHA
      terraform apply                       # autoscaling appears and fills it

    The last step is why the service must not simply be scaled up by hand:
    desired_count is in the service's ignore_changes list (Application Auto
    Scaling owns it), so it is min_capacity that raises the service to 2, not
    Terraform.
  EOT
  type        = bool
  default     = false
}

variable "desired_count" {
  description = "Initial task count. 2 so both AZs are occupied from the start. Forced to 0 when bootstrap = true."
  type        = number
  default     = 2
}

variable "min_capacity" {
  description = "Autoscaling floor. Must stay >= 2 to keep the multi-AZ claim true."
  type        = number
  default     = 2

  validation {
    condition     = var.min_capacity >= 2
    error_message = "min_capacity below 2 breaks the multi-AZ availability claim."
  }
}

variable "max_capacity" {
  description = "Autoscaling ceiling."
  type        = number
  default     = 6
}

variable "cpu_target_utilization" {
  description = <<-EOT
    Target-tracking setpoint for ECSServiceAverageCPUUtilization.

    CPU rather than ALBRequestCountPerTarget on purpose: that metric's
    resource_label must name a SPECIFIC target group, and under blue/green the
    production target group swaps on every deployment. CPU has no such
    coupling.

    60 is a placeholder until per-task Fargate capacity is measured -- see the
    benchmark step in the README. Thresholds follow the measurement.
  EOT
  type        = number
  default     = 60
}

variable "scale_in_cooldown" {
  description = "Seconds to wait before a further scale-in. Longer than scale-out: shedding capacity too eagerly is the expensive mistake."
  type        = number
  default     = 300
}

variable "scale_out_cooldown" {
  description = "Seconds to wait before a further scale-out."
  type        = number
  default     = 60
}

variable "health_check_grace_period_seconds" {
  description = <<-EOT
    How long ECS ignores load-balancer health for a newly started task. Must
    comfortably cover ORT session construction, otherwise ECS kills tasks that
    were merely still loading and the service never converges.
  EOT
  type        = number
  default     = 120
}

# --- Load balancer ----------------------------------------------------------

variable "health_check_path" {
  description = <<-EOT
    Target-group health check path. /ready, not /health: /health answers "the
    process is up", /ready answers "the ONNX session is loaded and this task
    can serve", returning 503 until then. Using /health would let the ALB route
    to a task that fails every request.
  EOT
  type        = string
  default     = "/ready"
}

variable "deregistration_delay" {
  description = "Connection-draining seconds. The 300s default makes every blue/green deployment crawl."
  type        = number
  default     = 30
}

variable "test_listener_port" {
  description = "Port for the CodeDeploy test listener, which fronts the green target group during a deployment."
  type        = number
  default     = 8080
}

variable "test_listener_allowed_cidrs" {
  description = <<-EOT
    CIDRs allowed to reach the test listener. Empty by default: CodeDeploy does
    NOT connect to the test listener itself -- it only re-points it -- so an
    open :8080 would be a second internet-facing entry point that buys nothing.
    Set this to ["<your.ip>/32"] to hand-validate the green task set during the
    bake window.
  EOT
  type        = list(string)
  default     = []
}

# --- Deployment -------------------------------------------------------------

variable "deployment_config_name" {
  description = <<-EOT
    CodeDeploy traffic-shift strategy.

    Canary rather than AllAtOnce, and the difference is the whole "zero
    downtime" claim. AllAtOnce moves 100% of traffic to the replacement task
    set and only THEN does the 5xx alarm need a full 60-second period to
    breach before rollback begins -- a real one-to-three minute outage, which
    contradicts the property this stack exists to demonstrate. Under canary
    only 10% of requests reach a bad build, the alarm fires on exactly the same
    signal, and the claim is true rather than aspirational.

    The cost is a ~6-minute deployment instead of a ~1-minute one.
    CodeDeployDefault.ECSLinear10PercentEvery1Minutes is the other realistic
    option and takes ten.
  EOT
  type        = string
  default     = "CodeDeployDefault.ECSCanary10Percent5Minutes"
}

variable "blue_termination_wait_minutes" {
  description = <<-EOT
    How long the original (blue) task set keeps running after traffic has
    shifted. This is the observation window: both task sets are alive and the
    rollback is a traffic shift back rather than a fresh deployment.
  EOT
  type        = number
  default     = 5
}

variable "deployment_ready_wait_minutes" {
  description = "Minutes CodeDeploy waits at the 'ready to reroute' gate before continuing automatically. 0 = continue immediately."
  type        = number
  default     = 0
}

# --- Observability ----------------------------------------------------------

variable "log_retention_days" {
  description = "CloudWatch Logs retention. The default is never-expire, which accrues cost silently."
  type        = number
  default     = 7
}

variable "container_insights" {
  description = "ECS Container Insights. Useful per-task metrics, but billed per metric -- off by default."
  type        = bool
  default     = false
}

# Both of these gate every deployment, which makes them higher-stakes than the
# autoscaling setpoint and subject to the same rule: they follow the Fargate
# measurement rather than preceding it. Too tight and every deploy rolls itself
# back, which reads as CodeDeploy being broken; too loose and a genuinely broken
# build ships. Correct order is apply -> benchmark through the ALB -> set these
# -> then attempt the rollback demonstration.

variable "alarm_5xx_threshold" {
  description = "HTTPCode_Target_5XX_Count over one minute that trips the rollback alarm."
  type        = number
  default     = 10
}

variable "alarm_p99_latency_seconds" {
  description = "TargetResponseTime p99, in seconds, that trips the rollback alarm."
  type        = number
  default     = 1.0
}

variable "enable_alb_access_logs" {
  description = <<-EOT
    Ship ALB access logs to S3. Pennies at this volume, and it is the
    difference between answering "how would you investigate a bad request after
    the fact" with a bucket rather than a shrug.
  EOT
  type        = bool
  default     = true
}

variable "access_log_retention_days" {
  description = "Days before ALB access log objects expire. The bucket is force_destroy, so teardown does not depend on this."
  type        = number
  default     = 7
}

variable "monthly_budget_usd" {
  description = <<-EOT
    AWS Budgets limit, account-wide. Free, and it mitigates the risk this stack
    actually has -- which is leaving it standing, not running it. At ~$0.13/hr
    the default trips within a few days of an accidental forever-deploy.
  EOT
  type        = number
  default     = 20
}

variable "budget_notification_email" {
  description = <<-EOT
    Address to notify at 80% actual and 100% forecast spend. Left empty the
    budget is still created and visible in the console, but nothing is
    delivered -- so set it. Deliberately has no default: an address baked into
    a committed tfvars file in a public repository is a mailing list waiting to
    happen.
  EOT
  type        = string
  default     = ""
}

# --- CI/CD identity ---------------------------------------------------------

variable "github_repo" {
  description = "owner/name of the repository allowed to assume the deploy role."
  type        = string
  default     = "JWanderer73/credit-card-fraud"

  validation {
    condition     = can(regex("^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$", var.github_repo))
    error_message = "github_repo must be in owner/name form."
  }
}

variable "github_branch" {
  description = <<-EOT
    Branch allowed to assume the deploy role. The trust policy is scoped to
    repo AND ref; scoping to the repo alone would let any branch -- including
    one pushed from a fork's pull request -- assume a role that can push images
    and start deployments.
  EOT
  type        = string
  default     = "main"
}

variable "create_github_oidc_provider" {
  description = <<-EOT
    An account may hold only one IAM OIDC provider per issuer URL. Set false if
    token.actions.githubusercontent.com is already registered in this account
    (by another stack, say) and it will be looked up instead of created.
  EOT
  type        = bool
  default     = true
}
