# ---------------------------------------------------------------------------
# ECS cluster, task definition, service.
# ---------------------------------------------------------------------------

resource "aws_ecs_cluster" "main" {
  name = local.name

  setting {
    name  = "containerInsights"
    value = var.container_insights ? "enabled" : "disabled"
  }

  tags = { Name = local.name }
}

resource "aws_ecs_cluster_capacity_providers" "main" {
  cluster_name       = aws_ecs_cluster.main.name
  capacity_providers = ["FARGATE"]

  default_capacity_provider_strategy {
    capacity_provider = "FARGATE"
    weight            = 1
  }
}

# ---------------------------------------------------------------------------
# Task definition.
#
# Terraform registers revision 1 and then stops caring. Every subsequent
# revision is registered by the deploy workflow with a git-SHA-tagged image and
# handed to CodeDeploy; Terraform's copy stays at the bootstrap tag on purpose,
# which is why the service ignores task_definition below.
# ---------------------------------------------------------------------------

resource "aws_ecs_task_definition" "app" {
  family                   = local.name
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.task_cpu
  memory                   = var.task_memory
  execution_role_arn       = aws_iam_role.task_execution.arn
  task_role_arn            = aws_iam_role.task.arn

  # Explicit rather than inherited. The image is built on GitHub's x86 runners
  # and never on the arm64 laptop, so pinning the architecture here makes a
  # mismatched push fail at task launch with a clear error instead of an
  # opaque exec-format failure inside the container.
  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }

  container_definitions = jsonencode([
    {
      name      = var.container_name
      image     = "${aws_ecr_repository.app.repository_url}:${var.image_tag}"
      essential = true

      portMappings = [
        {
          containerPort = var.container_port
          protocol      = "tcp"
        }
      ]

      environment = [
        { name = "WORKERS", value = tostring(var.uvicorn_workers) },
        { name = "ORT_INTRA_OP_THREADS", value = "1" },
      ]

      # ECS ignores the image's own HEALTHCHECK instruction, so it is restated
      # here. Same command as the Dockerfile: python:*-slim has no curl, and
      # adding one purely for a health check would put a package into the
      # runtime image.
      healthCheck = {
        command     = ["CMD-SHELL", "python -c \"import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:${var.container_port}/health', timeout=2).status==200 else 1)\""]
        interval    = 30
        timeout     = 5
        retries     = 3
        startPeriod = 30
      }

      # Time for uvicorn to finish in-flight requests after SIGTERM. The CMD's
      # `exec` is what makes this meaningful -- it puts uvicorn at PID 1 so the
      # signal reaches it rather than a shell that ignores it.
      stopTimeout = 30

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.app.name
          "awslogs-region"        = data.aws_region.current.region
          "awslogs-stream-prefix" = "ecs"
        }
      }
    }
  ])

  tags = { Name = local.name }
}

# ---------------------------------------------------------------------------
# Service.
# ---------------------------------------------------------------------------

resource "aws_ecs_service" "app" {
  name            = local.name
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.app.arn
  launch_type     = "FARGATE"

  # Zero on the first apply: the bootstrap image tag does not exist yet, and a
  # service at desired_count = 2 would spend the gap between apply and the
  # first workflow run churning task launches that can never pull. See the
  # `bootstrap` variable.
  desired_count = var.bootstrap ? 0 : var.desired_count

  # Pinned rather than LATEST. 1.4.0 is the platform version whose networking
  # model this endpoint set assumes: image pulls and log delivery traverse the
  # task ENI, control-plane traffic does not.
  platform_version = "1.4.0"

  deployment_controller {
    type = "CODE_DEPLOY"
  }

  network_configuration {
    subnets         = aws_subnet.private[*].id
    security_groups = [aws_security_group.task.id]

    # No public IP, and -- see network.tf -- no route to the internet either.
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.blue.arn
    container_name   = var.container_name
    container_port   = var.container_port
  }

  # Long enough for the ORT session to construct. Set too low, ECS kills tasks
  # that were merely still loading and the service never reaches steady state.
  health_check_grace_period_seconds = var.health_check_grace_period_seconds

  propagate_tags = "SERVICE"

  # Teardown is a deliverable here, not an afterthought. A CODE_DEPLOY-managed
  # service can be left holding task sets that CodeDeploy created and Terraform
  # has never seen, and DeleteService refuses while they are running -- so a
  # destroy stalls on the one resource that gates the ALB and the endpoints,
  # which are the two lines that actually accrue cost.
  force_delete = true

  # THE trap in this stack.
  #
  # With deployment_controller = CODE_DEPLOY, CodeDeploy owns the service's
  # task definition and load-balancer configuration from the first deployment
  # onwards. Terraform still holds revision 1 and the blue target group in
  # state, so without these exclusions every plan after every deployment
  # proposes reverting the running service to the bootstrap image and the
  # previous target group. It fails as a permanent diff rather than an error,
  # which is what makes it easy to miss and destructive to apply.
  #
  # desired_count is excluded for the same reason with a different owner:
  # Application Auto Scaling sets it, and Terraform would drag it back to the
  # floor on every apply.
  lifecycle {
    ignore_changes = [task_definition, load_balancer, desired_count]
  }

  # The listeners must exist before the service registers with the target
  # group, otherwise the ALB association races.
  depends_on = [
    aws_lb_listener.production,
    aws_lb_listener.test,
  ]

  tags = { Name = local.name }
}
