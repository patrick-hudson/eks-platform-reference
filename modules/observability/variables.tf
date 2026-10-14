variable "environment" {
  description = "Environment used for resource tags and naming."
  type        = string
}

variable "tags" {
  description = "Additional resource tags; required ownership tags take precedence."
  type        = map(string)
  default     = {}
}

variable "chart_version" {
  description = "Pinned kube-prometheus-stack chart version."
  type        = string
}

variable "namespace" {
  description = "Kubernetes namespace for monitoring."
  type        = string
}

variable "prometheus_retention" {
  description = "Prometheus local retention duration."
  type        = string
}

variable "prometheus_storage_size" {
  description = "Prometheus gp3 PVC capacity."
  type        = string
}

variable "grafana_storage_size" {
  description = "Grafana gp3 PVC capacity."
  type        = string
}

variable "prometheus_memory_request" {
  description = "Prometheus memory request in Kubernetes units."
  type        = string
}

variable "prometheus_memory_limit" {
  description = "Prometheus memory limit in Kubernetes units."
  type        = string
}

variable "region" {
  description = "AWS region, supplied explicitly to the ALB controller."
  type        = string
}

variable "cluster_name" {
  description = "EKS cluster name for the ALB controller."
  type        = string
}

variable "vpc_id" {
  description = "Cluster VPC for ALB reconciliation."
  type        = string
}

variable "public_subnet_ids" {
  description = "Public subnets for an internet-facing ALB in at least two zones."
  type        = list(string)
}

variable "controller_role_arn" {
  description = "IRSA role for the AWS Load Balancer Controller."
  type        = string
}

variable "controller_chart_version" {
  description = "Pinned AWS Load Balancer Controller chart version."
  type        = string
}

variable "hosted_zone_id" {
  description = "Existing public Route 53 hosted zone ID."
  type        = string
}

variable "grafana_hostname" {
  description = "Public Grafana hostname covered by the ACM certificate."
  type        = string
}

variable "load_balancer_name" {
  description = "Unique ALB name, at most 32 characters."
  type        = string
}

variable "ingress_cidrs" {
  description = "Client IPv4 CIDRs allowed to connect to Grafana."
  type        = list(string)
}
