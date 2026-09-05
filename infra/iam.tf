# ---------------------------------------------------------------------------
# Identity. Four roles, and no long-lived credentials anywhere.
#
#   github_actions   assumed by the workflow via OIDC; the only role a human
#                    or CI process ever holds against this account
#   task_execution   used by the ECS agent to pull the image and open log
#                    streams -- infrastructure, not application, identity
#   task             the application's own identity. Deliberately empty.
#   ecs_infrastructure  assumed by ECS itself to rewrite the load balancer's
#                    listener rules during a blue/green traffic shift
# ---------------------------------------------------------------------------

locals {
  partition  = data.aws_partition.current.partition
  account_id = data.aws_caller_identity.current.account_id
  region     = data.aws_region.current.region

  ecs_service_arn = "arn:${local.partition}:ecs:${local.region}:${local.account_id}:service/${aws_ecs_cluster.main.name}/${aws_ecs_service.app.name}"

  github_owner     = split("/", var.github_repo)[0]
  github_repo_name = split("/", var.github_repo)[1]

  oidc_provider_arn = var.create_github_oidc_provider ? aws_iam_openid_connect_provider.github[0].arn : data.aws_iam_openid_connect_provider.github[0].arn
}

# ---------------------------------------------------------------------------
# GitHub OIDC federation.
#
# The whole point: GitHub Actions exchanges a short-lived, workflow-scoped
# OIDC token for temporary AWS credentials. There is no access key to store as
# a repository secret, and therefore none to leak, rotate, or forget to revoke.
# ---------------------------------------------------------------------------

resource "aws_iam_openid_connect_provider" "github" {
  count = var.create_github_oidc_provider ? 1 : 0

  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]

  # No thumbprint_list. AWS stopped requiring a thumbprint for this issuer in
  # 2023 -- it validates token.actions.githubusercontent.com against its own
  # trust store -- and the provider now treats the argument as optional. The
  # thumbprints that used to be pasted in here were a rotation hazard: they
  # expire, and a stale one breaks every deployment at once.
  tags = { Name = "github-actions" }
}

# Only one OIDC provider per issuer URL is permitted per account, so an account
# that already has one needs it looked up rather than created.
data "aws_iam_openid_connect_provider" "github" {
  count = var.create_github_oidc_provider ? 0 : 1

  url = "https://token.actions.githubusercontent.com"
}

data "aws_iam_policy_document" "github_actions_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [local.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    # Scoped to the repository AND the ref -- not the repository alone.
    #
    # `repo:owner/name:*` is the version that appears in most tutorials, and it
    # is a real hole: any branch, and any pull request from a fork that manages
    # to run a workflow, would be able to assume a role that can push images to
    # ECR and start production deployments. Both patterns below pin the branch.
    #
    # TWO patterns, because GitHub has two subject formats and this cost a
    # failed deployment to discover. The documented-everywhere form is
    #
    #   repo:OWNER/NAME:ref:refs/heads/main
    #
    # but GitHub now issues an IMMUTABLE subject that carries the numeric owner
    # and repository IDs:
    #
    #   repo:OWNER@184721915/NAME@1356551646:ref:refs/heads/main
    #
    # The point of the IDs is that renaming an account or repository cannot
    # hand its trust to whoever claims the freed-up name. An exact StringEquals
    # on the documented form simply does not match, and the failure surfaces as
    # a bare "Not authorized to perform sts:AssumeRoleWithWebIdentity" with no
    # hint as to why -- the actual subject is only visible in CloudTrail's
    # AssumeRoleWithWebIdentity event.
    #
    # Matching both keeps this correct whether or not the immutable format is
    # in force. The wildcards cover only the ID segments, so this is exactly as
    # strong as the documented form: it still demands this owner login, this
    # repository name, and this branch.
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values = [
        "repo:${var.github_repo}:ref:refs/heads/${var.github_branch}",
        "repo:${local.github_owner}@*/${local.github_repo_name}@*:ref:refs/heads/${var.github_branch}",
      ]
    }
  }
}

resource "aws_iam_role" "github_actions" {
  name               = "${local.name}-github-actions"
  description        = "Assumed by GitHub Actions via OIDC to build, push and deploy."
  assume_role_policy = data.aws_iam_policy_document.github_actions_trust.json

  # An OIDC session that outlives the workflow that requested it is credential
  # sprawl by another name.
  max_session_duration = 3600

  tags = { Name = "${local.name}-github-actions" }
}

data "aws_iam_policy_document" "github_actions" {
  # ECR authentication is account-wide by design: the API returns a token, not
  # access to any particular repository, and it does not support resource-level
  # permissions.
  statement {
    sid       = "EcrAuth"
    effect    = "Allow"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    sid    = "EcrPushPull"
    effect = "Allow"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:InitiateLayerUpload",
      "ecr:UploadLayerPart",
      "ecr:CompleteLayerUpload",
      "ecr:PutImage",
      "ecr:BatchGetImage",
      "ecr:GetDownloadUrlForLayer",
      "ecr:DescribeImages",
      "ecr:DescribeRepositories",
    ]
    resources = [aws_ecr_repository.app.arn]
  }

  # RegisterTaskDefinition and DescribeTaskDefinition have no resource-level
  # permissions in IAM -- "*" is the only expressible resource. Noted rather
  # than quietly written, because it is the one place in this policy where the
  # scope is wider than intended and the reason is the API, not the author.
  statement {
    sid    = "EcsTaskDefinitions"
    effect = "Allow"
    actions = [
      "ecs:RegisterTaskDefinition",
      "ecs:DescribeTaskDefinition",
    ]
    resources = ["*"]
  }

  statement {
    sid       = "EcsDescribeService"
    effect    = "Allow"
    actions   = ["ecs:DescribeServices"]
    resources = [local.ecs_service_arn]
  }

  # For the workflow's post-deployment smoke test, which resolves the ALB's DNS
  # name rather than having it pasted into the workflow file. The ELB Describe
  # APIs do not support resource-level permissions.
  statement {
    sid       = "DescribeLoadBalancer"
    effect    = "Allow"
    actions   = ["elasticloadbalancing:DescribeLoadBalancers"]
    resources = ["*"]
  }

  # Replaces the three CodeDeploy statements the original design needed. With
  # ECS-native blue/green the deployment IS an UpdateService call, so there is
  # no second service to authorize, no application or deployment-group ARN to
  # scope, and no appspec revision to register.
  statement {
    sid       = "EcsDeploy"
    effect    = "Allow"
    actions   = ["ecs:UpdateService"]
    resources = [local.ecs_service_arn]
  }

  # PassRole is the privilege that matters here. Unscoped, it lets whoever
  # holds it register a task definition running any image under ANY role in the
  # account -- which is a full account takeover dressed up as a deployment.
  # Scoped to exactly the two roles this service uses, and conditioned on the
  # service they can be passed to.
  statement {
    sid     = "PassTaskRoles"
    effect  = "Allow"
    actions = ["iam:PassRole"]
    resources = [
      aws_iam_role.task_execution.arn,
      aws_iam_role.task.arn,
    ]

    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy" "github_actions" {
  name   = "${local.name}-deploy"
  role   = aws_iam_role.github_actions.id
  policy = data.aws_iam_policy_document.github_actions.json
}

# ---------------------------------------------------------------------------
# Task execution role -- the ECS agent's identity, not the application's.
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "ecs_tasks_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }

    # Prevents the confused-deputy case where another account's ECS service is
    # able to induce this role to be assumed on its behalf.
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }
}

resource "aws_iam_role" "task_execution" {
  name               = "${local.name}-task-execution"
  description        = "Pulls the image and opens log streams on the task's behalf."
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_trust.json

  tags = { Name = "${local.name}-task-execution" }
}

# Written out rather than attaching AmazonECSTaskExecutionRolePolicy. The
# managed policy grants ECR pull and log writes against every repository and
# every log group in the account; this grants them against this repository and
# this log group. Same capability, no reach beyond the stack.
data "aws_iam_policy_document" "task_execution" {
  statement {
    sid       = "EcrAuth"
    effect    = "Allow"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    sid    = "EcrPull"
    effect = "Allow"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:GetDownloadUrlForLayer",
      "ecr:BatchGetImage",
    ]
    resources = [aws_ecr_repository.app.arn]
  }

  # No logs:CreateLogGroup: the group is a Terraform resource with a retention
  # policy attached. Granting creation would let a misconfigured task quietly
  # make a second, never-expiring group instead of failing loudly.
  statement {
    sid    = "Logs"
    effect = "Allow"
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
    resources = ["${aws_cloudwatch_log_group.app.arn}:*"]
  }
}

resource "aws_iam_role_policy" "task_execution" {
  name   = "${local.name}-task-execution"
  role   = aws_iam_role.task_execution.id
  policy = data.aws_iam_policy_document.task_execution.json
}

# ---------------------------------------------------------------------------
# Task role -- the application's own identity.
#
# Intentionally has no policies attached. The application makes no AWS API
# calls: the model is baked into the image, configuration arrives as
# environment variables, and logs are shipped by the awslogs driver under the
# EXECUTION role, not this one. Creating the role and leaving it empty states
# that deliberately; attaching something "just in case" would be the failure.
# ---------------------------------------------------------------------------

resource "aws_iam_role" "task" {
  name               = "${local.name}-task"
  description        = "Application identity. Intentionally holds no permissions."
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_trust.json

  tags = { Name = "${local.name}-task" }
}

# ---------------------------------------------------------------------------
# ECS infrastructure role.
#
# Assumed by the ECS service itself -- not by a task, and not by CI. During a
# blue/green deployment ECS rewrites the load balancer's listener rules to move
# traffic between the two target groups; this is the identity it does that
# under. Omit it and the deployment fails immediately, before any task starts.
#
# This is the ECS-native replacement for what used to be the CodeDeploy service
# role, and it is a narrower grant: one AWS-managed policy covering load
# balancer mutation, rather than the whole ECS blue/green orchestration surface.
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "ecs_infrastructure_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ecs.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }
}

resource "aws_iam_role" "ecs_infrastructure" {
  name               = "${local.name}-ecs-infrastructure"
  description        = "Assumed by ECS to shift traffic between target groups during a blue/green deployment."
  assume_role_policy = data.aws_iam_policy_document.ecs_infrastructure_trust.json

  tags = { Name = "${local.name}-ecs-infrastructure" }
}

# The AWS-managed policy is the right call for a service role: its contents are
# defined by the service that consumes it, and AWS updates it when the
# mechanism needs a new permission. Hand-rolling it would mean tracking those
# changes by hand and finding out about a miss during a deployment.
resource "aws_iam_role_policy_attachment" "ecs_infrastructure" {
  role       = aws_iam_role.ecs_infrastructure.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/AmazonECSInfrastructureRolePolicyForLoadBalancers"
}
