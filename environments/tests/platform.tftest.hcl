variable "test_workspace" { type = string }
variable "environments" { type = any }
# Offline provider plans still run real AWS resource schemas and IAM JSON rendering.
provider "aws" {
  region                      = var.environments[var.test_workspace].region
  access_key                  = "offline-testing"
  secret_key                  = "offline-testing"
  skip_credentials_validation = true
  skip_requesting_account_id  = true
  skip_metadata_api_check     = true
}
override_data {
  target = data.aws_caller_identity.current
  values = { account_id = "111122223333", arn = "arn:aws:iam::111122223333:user/test", user_id = "test" }
}
override_data {
  target = data.aws_partition.current
  values = { partition = "aws", dns_suffix = "amazonaws.com", reverse_dns_prefix = "com.amazonaws" }
}
override_data {
  target = module.cluster.data.aws_partition.current
  values = { partition = "aws", dns_suffix = "amazonaws.com", reverse_dns_prefix = "com.amazonaws" }
}
override_data {
  target = module.cluster.data.aws_eks_addon_version.this
  values = { version = "v1.0.0-eksbuild.1" }
}
run "platform_plan" {
  command = plan
  assert {
    condition     = output.environment == var.test_workspace && output.cluster_name == var.environments[var.test_workspace].cluster_name
    error_message = "Workspace selection must choose the matching environment settings."
  }
  assert {
    condition     = length(output.nat_public_ips) == (var.environments[var.test_workspace].single_nat_gateway ? 1 : length(var.environments[var.test_workspace].subnets))
    error_message = "NAT topology must match the environment's cost and availability choice."
  }
  assert {
    condition     = length(output.private_subnet_ids) == length(var.environments[var.test_workspace].subnets)
    error_message = "Every configured zone needs a private node subnet."
  }
  assert {
    condition     = toset(keys(output.irsa_role_arns)) == toset(["cni", "ebs", "alb"])
    error_message = "AWS controllers need distinct service account roles."
  }
}

run "reject_missing_workspace_settings" {
  command = plan
  variables { environments = {} }
  expect_failures = [var.environments]
}
