variable "environments" {
  description = "Environment settings keyed by Terraform workspace; loaded automatically from terraform.tfvars."
  type = map(object({
    # AWS region for the environment.
    region = string
    # EKS name, shared with bootstrap configuration.
    cluster_name = string
    # Non-overlapping VPC CIDR.
    vpc_cidr = string
    # Explicit AZ and subnet CIDRs.
    subnets = map(object({ availability_zone = string, public_cidr = string, private_cidr = string }))
    # Share one NAT gateway across zones.
    single_nat_gateway = bool
    # Internet route destination CIDR.
    internet_cidr = string
    # EKS Kubernetes minor version.
    kubernetes_version = string
    # Kubernetes API public ingress CIDRs.
    public_access_cidrs = list(string)
    # Managed node EC2 instance types.
    instance_types = list(string)
    # Managed node scaling settings.
    node_sizes = object({ min = number, desired = number, max = number })
    # Node root volume GiB.
    node_disk_size = number
    # Control plane log retention.
    log_retention_days = number
    # Bootstrap-created deploy role name.
    deploy_role_name = string
    # Bootstrap-created plan role name.
    plan_role_name = string
    # Stable names of human administrator IAM roles, never STS session ARNs.
    administrator_arns = optional(map(string), {})
  }))

  validation {
    condition     = terraform.workspace != "default" && contains(keys(var.environments), terraform.workspace)
    error_message = "Select a named workspace with settings in terraform.tfvars, such as dev or prod."
  }
}
