output "region" {
  description = "AWS region."
  value       = local.settings.region
}

output "cluster_name" {
  description = "EKS cluster name."
  value       = module.cluster.cluster_name
}

output "cluster_endpoint" {
  description = "Kubernetes API endpoint."
  value       = module.cluster.cluster_endpoint
}

output "vpc_id" {
  description = "Environment VPC."
  value       = module.network.vpc_id
}

output "private_subnet_ids" {
  description = "Private subnets."
  value       = module.network.private_subnet_ids
}

output "nat_public_ips" {
  description = "NAT egress addresses."
  value       = module.network.nat_public_ips
}

output "oidc_provider_arn" {
  description = "IRSA provider ARN."
  value       = module.cluster.oidc_provider_arn
}

output "oidc_issuer_url" {
  description = "IRSA issuer URL."
  value       = module.cluster.oidc_issuer_url
}

output "irsa_role_arns" {
  description = "Add-on IAM roles."
  value       = module.cluster.irsa_role_arns
}

output "environment" {
  description = "Selected Terraform workspace."
  value       = terraform.workspace
}
