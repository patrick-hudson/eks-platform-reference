output "namespace" {
  description = "Monitoring namespace."
  value       = module.observability.namespace
}

output "grafana_service" {
  description = "Grafana service for port-forward."
  value       = module.observability.grafana_service
}

output "grafana_secret" {
  description = "Grafana admin credential secret."
  value       = module.observability.grafana_secret
}

output "grafana_url" {
  description = "Public Grafana HTTPS endpoint."
  value       = module.observability.grafana_url
}

output "environment" {
  description = "Selected Terraform workspace."
  value       = terraform.workspace
}

output "hosted_zone_id" {
  description = "Public hosted zone selected for ingress and certificate validation."
  value       = data.aws_route53_zone.public.zone_id
}
