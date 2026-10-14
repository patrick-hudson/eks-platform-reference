environments = {
  dev = {
    region                    = "us-east-1"
    cluster_name              = "eks-platform-reference-dev"
    chart_version             = "92.7.0"
    namespace                 = "monitoring"
    prometheus_retention      = "2d"
    prometheus_storage_size   = "10Gi"
    grafana_storage_size      = "5Gi"
    prometheus_memory_request = "512Mi"
    prometheus_memory_limit   = "1Gi"

    domain_name              = "hudson.tf"
    grafana_hostname         = "grafana.dev.hudson.tf"
    load_balancer_name       = "eks-reference-dev-grafana"
    controller_chart_version = "1.14.1"
    ingress_cidrs            = ["0.0.0.0/0"]
    hosted_zone_id           = "Z0992412PWY8TUM0P6ZU"
  }

  prod = {
    region                    = "us-east-1"
    cluster_name              = "eks-platform-reference-prod"
    chart_version             = "92.7.0"
    namespace                 = "monitoring"
    prometheus_retention      = "7d"
    prometheus_storage_size   = "30Gi"
    grafana_storage_size      = "5Gi"
    prometheus_memory_request = "1Gi"
    prometheus_memory_limit   = "2Gi"

    domain_name              = "hudson.tf"
    grafana_hostname         = "grafana.prod.hudson.tf"
    load_balancer_name       = "eks-reference-prod-grafana"
    controller_chart_version = "1.14.1"
    ingress_cidrs            = ["0.0.0.0/0"]
    hosted_zone_id           = "Z0992412PWY8TUM0P6ZU"
  }
}
