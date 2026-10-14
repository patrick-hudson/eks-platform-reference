output "state_bucket_name" {
  description = "S3 backend bucket."
  value       = aws_s3_bucket.state.id
}

output "github_role_arns" {
  description = "Apply and plan role ARNs by environment."
  value       = { for k, role in module.pipeline : k => role.role_arn }
}

output "github_oidc_provider_arn" {
  description = "Shared GitHub OIDC provider ARN."
  value       = local.github_oidc_provider_arn
}

output "hosted_zone_id" {
  description = "Public hosted zone selected for ingress and certificate validation."
  value       = data.aws_route53_zone.public.zone_id
}
