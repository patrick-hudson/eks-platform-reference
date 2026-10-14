variable "environments" {
  description = "Environment settings keyed by Terraform workspace; loaded automatically from terraform.tfvars."
  type = map(object({
    # Cluster AWS region.
    region = string
    # Existing EKS cluster name.
    cluster_name = string
    # Pinned kube-prometheus-stack chart.
    chart_version = string
    # Monitoring namespace.
    namespace = string
    # Prometheus retention duration.
    prometheus_retention = string
    # Prometheus storage in integer Gi units.
    prometheus_storage_size = string
    # Grafana storage capacity.
    grafana_storage_size = string
    # Prometheus memory request.
    prometheus_memory_request = string
    # Prometheus memory limit.
    prometheus_memory_limit = string
    # Existing public Route 53 hosted zone name.
    domain_name = string
    # Public HTTPS Grafana hostname.
    grafana_hostname = string
    # Unique ALB name, maximum 32 characters.
    load_balancer_name = string
    # AWS Load Balancer Controller chart pin.
    controller_chart_version = string
    # Client CIDRs permitted to reach Grafana.
    ingress_cidrs = list(string)
    # Exact existing public Route 53 zone ID; zone names are not unique.
    hosted_zone_id = string
  }))

  validation {
    condition     = terraform.workspace != "default" && contains(keys(var.environments), terraform.workspace)
    error_message = "Select a named workspace with settings in terraform.tfvars, such as dev or prod."
  }
}
