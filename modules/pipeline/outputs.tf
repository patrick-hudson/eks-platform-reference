output "role_arn" {
  description = "Role ARN for the GitHub environment AWS_ROLE_ARN variable."
  value       = aws_iam_role.this.arn
}

output "oidc_subject" {
  description = "Exact accepted GitHub OIDC subject."
  value       = "repo:${var.github_repository}:environment:${var.github_environment}"
}
