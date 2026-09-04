# ---------------------------------------------------------------------------
# Outputs.
#
# The deploy workflow reads several of these (the role ARN once, by hand, into
# a repository variable; the rest are derived from project/environment and kept
# in the workflow's env block). The verification outputs exist so the evidence
# steps in the README are copy-paste rather than a hunt through the console.
# ---------------------------------------------------------------------------

output "alb_dns_name" {
  description = "Public DNS name of the load balancer."
  value       = aws_lb.main.dns_name
}

output "api_url" {
  description = "Base URL of the API. HTTP only -- see the HTTPS gap noted in alb.tf."
  value       = "http://${aws_lb.main.dns_name}"
}

output "docs_url" {
  description = "Interactive OpenAPI docs, through the load balancer."
  value       = "http://${aws_lb.main.dns_name}/docs"
}

output "ecr_repository_url" {
  description = "Push target for the deploy workflow."
  value       = aws_ecr_repository.app.repository_url
}

output "ecr_repository_name" {
  description = "Repository name, for the workflow's env block."
  value       = aws_ecr_repository.app.name
}

output "ecs_cluster_name" {
  description = "ECS cluster name."
  value       = aws_ecs_cluster.main.name
}

output "ecs_service_name" {
  description = "ECS service name."
  value       = aws_ecs_service.app.name
}

output "task_definition_family" {
  description = "Family the deploy workflow registers new revisions under."
  value       = aws_ecs_task_definition.app.family
}

output "codedeploy_application_name" {
  description = "CodeDeploy application."
  value       = aws_codedeploy_app.app.name
}

output "codedeploy_deployment_group_name" {
  description = "CodeDeploy deployment group."
  value       = aws_codedeploy_deployment_group.app.deployment_group_name
}

output "github_actions_role_arn" {
  description = <<-EOT
    Set this as the AWS_DEPLOY_ROLE_ARN repository variable in GitHub. It is
    the only piece of AWS configuration the repository holds, and it is not a
    secret: it is useless without an OIDC token whose `sub` matches the trust
    policy.
  EOT
  value       = aws_iam_role.github_actions.arn
}

output "alb_access_logs_bucket" {
  description = "Bucket holding ALB access logs, or null when they are disabled."
  value       = var.enable_alb_access_logs ? aws_s3_bucket.alb_logs[0].id : null
}

output "budget_name" {
  description = "Account-wide monthly budget guarding against leaving the stack standing."
  value       = aws_budgets_budget.monthly.name
}

output "log_group_name" {
  description = "CloudWatch log group carrying application logs."
  value       = aws_cloudwatch_log_group.app.name
}

# --- Verification handles ---------------------------------------------------

output "task_security_group_id" {
  description = "Subject of the 'ingress only from the ALB' evidence step."
  value       = aws_security_group.task.id
}

output "alb_security_group_id" {
  description = "The only security group in the stack with an internet-facing rule."
  value       = aws_security_group.alb.id
}

output "endpoint_security_group_id" {
  description = "Interface VPC endpoint ENIs."
  value       = aws_security_group.endpoint.id
}

output "vpc_id" {
  description = "VPC id."
  value       = aws_vpc.main.id
}

output "private_subnet_ids" {
  description = "Subnets the tasks run in. Their route tables carry no default route."
  value       = aws_subnet.private[*].id
}

output "private_route_table_ids" {
  description = "Show these to prove there is no 0.0.0.0/0 route out of the task subnets."
  value       = aws_route_table.private[*].id
}

output "target_group_names" {
  description = "The blue/green pair. Which one is serving production alternates with each deployment."
  value = {
    blue  = aws_lb_target_group.blue.name
    green = aws_lb_target_group.green.name
  }
}

output "deployment_config_name" {
  description = "CodeDeploy traffic-shift strategy in force."
  value       = aws_codedeploy_deployment_group.app.deployment_config_name
}

output "rollback_alarm_names" {
  description = "Alarms wired into CodeDeploy's auto-rollback trigger."
  value = [
    aws_cloudwatch_metric_alarm.target_5xx.alarm_name,
    aws_cloudwatch_metric_alarm.p99_latency.alarm_name,
  ]
}
