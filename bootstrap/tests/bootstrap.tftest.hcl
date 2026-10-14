variable "region" { type = string }
provider "aws" {
  region                      = var.region
  access_key                  = "offline-testing"
  secret_key                  = "offline-testing"
  skip_credentials_validation = true
  skip_requesting_account_id  = true
  skip_metadata_api_check     = true
}
override_data {
  target = data.aws_route53_zone.public
  values = { zone_id = "ZOFFLINETEST", name = "offline.invalid", private_zone = false }
}
override_data {
  target = module.pipeline["dev-plan"].data.aws_caller_identity.current
  values = { account_id = "111122223333", arn = "arn:aws:iam::111122223333:user/test", user_id = "test" }
}
override_data {
  target = module.pipeline["dev-plan"].data.aws_partition.current
  values = { partition = "aws", dns_suffix = "amazonaws.com", reverse_dns_prefix = "com.amazonaws" }
}
override_data {
  target = module.pipeline["dev-apply"].data.aws_caller_identity.current
  values = { account_id = "111122223333", arn = "arn:aws:iam::111122223333:user/test", user_id = "test" }
}
override_data {
  target = module.pipeline["dev-apply"].data.aws_partition.current
  values = { partition = "aws", dns_suffix = "amazonaws.com", reverse_dns_prefix = "com.amazonaws" }
}
override_data {
  target = module.pipeline["prod-plan"].data.aws_caller_identity.current
  values = { account_id = "111122223333", arn = "arn:aws:iam::111122223333:user/test", user_id = "test" }
}
override_data {
  target = module.pipeline["prod-plan"].data.aws_partition.current
  values = { partition = "aws", dns_suffix = "amazonaws.com", reverse_dns_prefix = "com.amazonaws" }
}
override_data {
  target = module.pipeline["prod-apply"].data.aws_caller_identity.current
  values = { account_id = "111122223333", arn = "arn:aws:iam::111122223333:user/test", user_id = "test" }
}
override_data {
  target = module.pipeline["prod-apply"].data.aws_partition.current
  values = { partition = "aws", dns_suffix = "amazonaws.com", reverse_dns_prefix = "com.amazonaws" }
}
run "bootstrap_plan" {
  command = plan
  variables {
    state_bucket_name        = "offline-eks-reference-state"
    github_repository        = "offline/eks-platform-reference"
    github_oidc_provider_arn = "arn:aws:iam::111122223333:oidc-provider/token.actions.githubusercontent.com"
    domain_name              = "offline.invalid"
    hosted_zone_id           = "ZOFFLINETEST"
    environments = {
      dev  = { cluster_name = "offline-dev", deploy_role_name = "offline-dev-apply", plan_role_name = "offline-dev-plan" }
      prod = { cluster_name = "offline-prod", deploy_role_name = "offline-prod-apply", plan_role_name = "offline-prod-plan" }
    }
  }
  assert {
    condition     = aws_s3_bucket_versioning.state.versioning_configuration[0].status == "Enabled" && aws_s3_bucket_public_access_block.state.block_public_policy && aws_s3_bucket_public_access_block.state.block_public_acls
    error_message = "State must have versioning and public access blocking."
  }
  assert {
    condition     = alltrue([for name, role in module.pipeline : role.oidc_subject == "repo:offline/eks-platform-reference:environment:${replace(name, "-apply", "")}"])
    error_message = "Bootstrap must wire each CI role to its matching GitHub environment."
  }
}
