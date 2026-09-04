# ---------------------------------------------------------------------------
# Logs and alarms.
#
# The alarms here are not decorative. Two of them are named in the ECS
# service's `alarms` block (see ecs.tf), which is what turns "we have alarms"
# into "a bad deployment shifts traffic back on its own".
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_log_group" "app" {
  name = "/ecs/${local.name}"

  # The default is never-expire, which accrues cost quietly forever. Seven days
  # is more than enough for a stack whose whole purpose is a few hours of
  # evidence capture.
  retention_in_days = var.log_retention_days

  tags = { Name = local.name }
}

# --- Rollback alarms --------------------------------------------------------
#
# Both are scoped to the LOAD BALANCER dimension rather than to a target group.
# That is deliberate: under blue/green the production target group alternates
# on every deployment, so a target-group-scoped alarm would be watching the
# idle group half the time. The load balancer is the one dimension whose
# meaning is stable across the swap.

resource "aws_cloudwatch_metric_alarm" "target_5xx" {
  alarm_name          = "${local.name}-target-5xx"
  alarm_description   = "Application returning 5XX. Wired to ECS deployment auto-rollback."
  namespace           = "AWS/ApplicationELB"
  metric_name         = "HTTPCode_Target_5XX_Count"
  statistic           = "Sum"
  period              = 60
  evaluation_periods  = 1
  threshold           = var.alarm_5xx_threshold
  comparison_operator = "GreaterThanOrEqualToThreshold"

  dimensions = {
    LoadBalancer = aws_lb.main.arn_suffix
  }

  # An idle load balancer emits no datapoints for this metric. Without this the
  # alarm sits in INSUFFICIENT_DATA, which an alarm-gated deployment cannot
  # evaluate -- so a bad build would ship unchallenged.
  treat_missing_data = "notBreaching"

  tags = { Name = "${local.name}-target-5xx" }
}

resource "aws_cloudwatch_metric_alarm" "p99_latency" {
  alarm_name          = "${local.name}-p99-latency"
  alarm_description   = "p99 target response time above budget. Wired to ECS deployment auto-rollback."
  namespace           = "AWS/ApplicationELB"
  metric_name         = "TargetResponseTime"
  extended_statistic  = "p99"
  period              = 60
  evaluation_periods  = 2
  threshold           = var.alarm_p99_latency_seconds
  comparison_operator = "GreaterThanThreshold"

  dimensions = {
    LoadBalancer = aws_lb.main.arn_suffix
  }

  treat_missing_data = "notBreaching"

  tags = { Name = "${local.name}-p99-latency" }
}

# --- Observability-only alarm ----------------------------------------------
#
# UnHealthyHostCount is monitored but deliberately NOT wired into the rollback
# trigger, which is a departure from the phase plan worth stating plainly.
#
# A blue/green deployment necessarily registers a fresh, not-yet-healthy task
# set into the standby target group; those tasks are legitimately unhealthy for
# the ~45s it takes ORT to load and two health checks to pass. An
# UnHealthyHostCount alarm in the rollback set would therefore fire on the
# deployment's own normal startup and roll back perfectly good releases -- the
# alarm would be measuring the deployment rather than the application.
#
# The 5XX and latency alarms have no such coupling: they only see traffic that
# has actually been routed. Sustained unhealthy hosts still page here; they
# just do not get a veto over deployments.

resource "aws_cloudwatch_metric_alarm" "unhealthy_hosts" {
  for_each = {
    blue  = aws_lb_target_group.blue.arn_suffix
    green = aws_lb_target_group.green.arn_suffix
  }

  alarm_name        = "${local.name}-unhealthy-hosts-${each.key}"
  alarm_description = "Sustained unhealthy targets in the ${each.key} target group."
  namespace         = "AWS/ApplicationELB"
  metric_name       = "UnHealthyHostCount"
  statistic         = "Maximum"
  period            = 60
  # Three periods, so a normal deployment's startup window cannot trip it.
  evaluation_periods  = 3
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"

  dimensions = {
    TargetGroup  = each.value
    LoadBalancer = aws_lb.main.arn_suffix
  }

  # A drained target group reports no datapoints at all; that is the normal
  # resting state for whichever group is idle, not a fault.
  treat_missing_data = "notBreaching"

  tags = { Name = "${local.name}-unhealthy-hosts-${each.key}" }
}

# ---------------------------------------------------------------------------
# ALB access logs.
#
# The application's own logs live and die with the task set; access logs do
# not. After a blue/green rollback the task that served the bad requests is
# gone, and this bucket is the only remaining per-request record of what it was
# asked and what it answered.
# ---------------------------------------------------------------------------

resource "aws_s3_bucket" "alb_logs" {
  count = var.enable_alb_access_logs ? 1 : 0

  bucket = "${local.name}-alb-logs-${local.account_id}"

  # The bucket will contain logs when destroy runs, and the point of this stack
  # is that teardown is a single command that does not stall.
  force_destroy = true

  tags = { Name = "${local.name}-alb-logs" }
}

resource "aws_s3_bucket_public_access_block" "alb_logs" {
  count = var.enable_alb_access_logs ? 1 : 0

  bucket = aws_s3_bucket.alb_logs[0].id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "alb_logs" {
  count = var.enable_alb_access_logs ? 1 : 0

  bucket = aws_s3_bucket.alb_logs[0].id

  rule {
    apply_server_side_encryption_by_default {
      # SSE-S3, not SSE-KMS with a customer key: ALB access log delivery
      # supports AES256 and aws:kms with the S3 managed key only, and silently
      # stops delivering rather than erroring if it cannot write.
      sse_algorithm = "AES256"
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "alb_logs" {
  count = var.enable_alb_access_logs ? 1 : 0

  bucket = aws_s3_bucket.alb_logs[0].id

  rule {
    id     = "expire-access-logs"
    status = "Enabled"

    filter {}

    expiration {
      days = var.access_log_retention_days
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

# Which principal writes the logs depends on how old the region is, and getting
# it wrong produces silence rather than an error -- the ALB simply never
# delivers. Regions enabled before August 2022 (us-east-1 among them) are
# written to by a per-region ELB account; newer ones use a service principal.
# Both are granted, so the module is correct in either.
data "aws_elb_service_account" "main" {
  count = var.enable_alb_access_logs ? 1 : 0
}

data "aws_iam_policy_document" "alb_logs" {
  count = var.enable_alb_access_logs ? 1 : 0

  statement {
    sid    = "ElbAccountPutObject"
    effect = "Allow"

    principals {
      type        = "AWS"
      identifiers = [data.aws_elb_service_account.main[0].arn]
    }

    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.alb_logs[0].arn}/${local.name}/AWSLogs/${local.account_id}/*"]
  }

  statement {
    sid    = "LogDeliveryPutObject"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["logdelivery.elasticloadbalancing.amazonaws.com"]
    }

    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.alb_logs[0].arn}/${local.name}/AWSLogs/${local.account_id}/*"]

    condition {
      test     = "StringEquals"
      variable = "s3:x-amz-acl"
      values   = ["bucket-owner-full-control"]
    }
  }

  statement {
    sid    = "LogDeliveryGetBucketAcl"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["logdelivery.elasticloadbalancing.amazonaws.com"]
    }

    actions   = ["s3:GetBucketAcl"]
    resources = [aws_s3_bucket.alb_logs[0].arn]
  }
}

resource "aws_s3_bucket_policy" "alb_logs" {
  count = var.enable_alb_access_logs ? 1 : 0

  bucket = aws_s3_bucket.alb_logs[0].id
  policy = data.aws_iam_policy_document.alb_logs[0].json

  # A bucket policy applied before the public access block can be rejected as
  # a public policy while the block is still absent.
  depends_on = [aws_s3_bucket_public_access_block.alb_logs]
}

# ---------------------------------------------------------------------------
# Budget.
#
# The honest risk in this phase is not the hourly rate, it is forgetting the
# stack is up. Budgets cost nothing, and this is account-wide rather than
# tag-filtered on purpose: tag-based cost filters need cost allocation tags
# activated by hand and take up to 24 hours to start matching, which is exactly
# long enough to be useless for the window that matters here.
# ---------------------------------------------------------------------------

resource "aws_budgets_budget" "monthly" {
  name         = "${local.name}-monthly"
  budget_type  = "COST"
  limit_amount = tostring(var.monthly_budget_usd)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  dynamic "notification" {
    for_each = var.budget_notification_email == "" ? [] : [
      { type = "ACTUAL", threshold = 80 },
      { type = "FORECASTED", threshold = 100 },
    ]

    content {
      comparison_operator        = "GREATER_THAN"
      threshold                  = notification.value.threshold
      threshold_type             = "PERCENTAGE"
      notification_type          = notification.value.type
      subscriber_email_addresses = [var.budget_notification_email]
    }
  }
}
