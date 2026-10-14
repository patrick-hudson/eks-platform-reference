output "cluster_name" {
  description = "Cluster name for CLI and Helm authentication."
  value       = aws_eks_cluster.this.name
}

output "cluster_endpoint" {
  description = "Kubernetes API endpoint."
  value       = aws_eks_cluster.this.endpoint
}

output "cluster_certificate_authority_data" {
  description = "Base64 encoded Kubernetes CA."
  value       = aws_eks_cluster.this.certificate_authority[0].data
}

output "cluster_security_group_id" {
  description = "EKS managed security group."
  value       = aws_eks_cluster.this.vpc_config[0].cluster_security_group_id
}

output "oidc_provider_arn" {
  description = "IRSA OIDC provider ARN."
  value       = aws_iam_openid_connect_provider.this.arn
}

output "oidc_issuer_url" {
  description = "IRSA issuer for future service account trust policies."
  value       = aws_iam_openid_connect_provider.this.url
}

output "irsa_role_arns" {
  description = "Service account roles for CNI and EBS CSI."
  value       = { for k, role in aws_iam_role.irsa : k => role.arn }
}

output "node_group_name" {
  description = "Managed node group name."
  value       = aws_eks_node_group.this.node_group_name
}
