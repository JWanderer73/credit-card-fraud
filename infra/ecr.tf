# ---------------------------------------------------------------------------
# Container registry.
# ---------------------------------------------------------------------------

resource "aws_ecr_repository" "app" {
  name = local.name

  # IMMUTABLE pairs with git-SHA tagging: a tag can never be moved to point at
  # different bytes, so "which commit is running" is answerable from the tag
  # alone. The cost is that re-running the deploy workflow on an unchanged SHA
  # fails the push -- which is the correct outcome, not a bug to work around.
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
  }

  # So `terraform destroy` completes without a manual image sweep. The workflow
  # rebuilds and re-pushes on the next deploy, so nothing durable is lost.
  force_delete = true

  tags = { Name = local.name }
}

resource "aws_ecr_lifecycle_policy" "app" {
  repository = aws_ecr_repository.app.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Expire untagged images after 1 day"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 1
        }
        action = { type = "expire" }
      },
      {
        rulePriority = 2
        description  = "Keep only the 10 most recent images"
        selection = {
          # "any" rather than a tag pattern: ECR requires the catch-all rule to
          # be the last one by priority, and with rule 1 already sweeping
          # untagged images this is effectively "keep the last 10 releases".
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = 10
        }
        action = { type = "expire" }
      },
    ]
  })
}
