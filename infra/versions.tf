# ---------------------------------------------------------------------------
# Provider, version pinning, and remote state.
#
# The backend is DELIBERATELY partial: S3 bucket names are globally unique, so
# hard-coding one makes the module unusable in any other account. The bucket is
# created out-of-band by scripts/bootstrap-state.sh, which also writes
# infra/backend.hcl:
#
#     terraform init -backend-config=backend.hcl
#
# State locking uses S3 native conditional writes (`use_lockfile`), available
# since Terraform 1.10 and stable in 1.16. That removes the DynamoDB lock table
# this stack would otherwise need -- one fewer resource, one fewer thing to pay
# for, one fewer thing to forget to destroy.
# ---------------------------------------------------------------------------

terraform {
  required_version = ">= 1.10.0, < 2.0.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  backend "s3" {
    key          = "credit-card-fraud/terraform.tfstate"
    encrypt      = true
    use_lockfile = true
  }
}

provider "aws" {
  region = var.aws_region

  # Applied to every taggable resource in the stack, so teardown verification
  # is a single tag query rather than a resource-by-resource hunt.
  default_tags {
    tags = {
      Project     = var.project
      Environment = var.environment
      ManagedBy   = "terraform"
      Repository  = var.github_repo
    }
  }
}

data "aws_region" "current" {}
data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}
