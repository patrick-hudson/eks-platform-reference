variable "region" {
  description = "AWS region for state and locking."
  type        = string
}

variable "state_bucket_name" {
  description = "Globally unique S3 state bucket name."
  type        = string
}

variable "github_repository" {
  description = "GitHub owner/repository that will run the workflows."
  type        = string
}

variable "github_oidc_provider_arn" {
  description = "Existing account GitHub provider ARN; null creates it here."
  type        = string
  default     = null
}

variable "environments" {
  description = "Environment names and the cluster and CI role names for each."
  type        = map(object({ cluster_name = string, deploy_role_name = string, plan_role_name = string }))
}

variable "domain_name" {
  description = "Existing public Route 53 hosted zone name."
  type        = string
}

variable "hosted_zone_id" {
  description = "Exact existing public Route 53 zone ID; zone names are not unique."
  type        = string
}
