variable "environment" {
  description = "Environment used for resource tags and naming."
  type        = string
}

variable "tags" {
  description = "Additional resource tags; required ownership tags take precedence."
  type        = map(string)
  default     = {}
}

variable "github_repository" {
  description = "Repository portion of GitHub's OIDC sub_claim_prefix, without repo:. Include immutable owner/repository IDs when GitHub reports them."
  type        = string
}

variable "github_environment" {
  description = "Exact GitHub environment in the OIDC subject."
  type        = string
}

variable "oidc_provider_arn" {
  description = "Shared account-level GitHub OIDC provider ARN."
  type        = string
}

variable "role_name" {
  description = "IAM role name for this environment and permission level."
  type        = string
}

variable "cluster_name" {
  description = "Cluster whose IAM role prefix the deploy role may manage."
  type        = string
}

variable "region" {
  description = "AWS region in which service operations are permitted."
  type        = string
}

variable "state_bucket_arn" {
  description = "State bucket ARN."
  type        = string
}

variable "state_prefix" {
  description = "Environment-specific state key prefix including trailing slash."
  type        = string
}

variable "read_only" {
  description = "Create a plan role without AWS write permissions."
  type        = bool
}

variable "hosted_zone_id" {
  description = "Existing Route 53 zone in which certificates and ingress records are managed."
  type        = string
}
