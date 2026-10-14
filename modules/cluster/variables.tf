variable "environment" {
  description = "Environment used for resource tags and naming."
  type        = string
}

variable "tags" {
  description = "Additional resource tags; required ownership tags take precedence."
  type        = map(string)
  default     = {}
}

variable "cluster_name" {
  description = "EKS cluster name and prefix for its IAM roles."
  type        = string
}

variable "kubernetes_version" {
  description = "EKS Kubernetes minor version in standard support."
  type        = string
}

variable "subnet_ids" {
  description = "Private subnet IDs for the cluster and nodes."
  type        = list(string)
}

variable "public_access_cidrs" {
  description = "CIDRs permitted to reach the public Kubernetes API."
  type        = list(string)
}

variable "instance_types" {
  description = "EC2 instance types for the managed node group."
  type        = list(string)
}

variable "node_sizes" {
  description = "Minimum, desired and maximum node counts."
  type        = object({ min = number, desired = number, max = number })
}

variable "node_disk_size" {
  description = "Encrypted root volume size in GiB."
  type        = number
}

variable "log_retention_days" {
  description = "CloudWatch control plane log retention."
  type        = number
}

variable "access_entries" {
  description = "Stable entry names mapped to IAM principals and EKS access policy names."
  type        = map(object({ principal_arn = string, policy_name = string }))
}
