output "namespace" {
  description = "Monitoring namespace."
  value       = helm_release.monitoring.namespace
}

output "release_name" {
  description = "Helm release name."
  value       = helm_release.monitoring.name
}

output "grafana_service" {
  description = "Grafana ClusterIP service for port forwarding."
  value       = "${helm_release.monitoring.name}-grafana"
}

output "grafana_secret" {
  description = "Secret holding the generated Grafana admin password."
  value       = "${helm_release.monitoring.name}-grafana"
}

output "grafana_url" {
  description = "Public Grafana HTTPS URL, with authentication required."
  value       = "https://${aws_route53_record.grafana.name}"
}
output "load_balancer_dns_name" {
  description = "Controller-managed ALB DNS name."
  value       = data.aws_lb.grafana.dns_name
}
