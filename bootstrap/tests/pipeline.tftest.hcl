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
  target = data.aws_caller_identity.current
  values = { account_id = "111122223333", arn = "arn:aws:iam::111122223333:user/test", user_id = "test" }
}
override_data {
  target = data.aws_partition.current
  values = { partition = "aws", dns_suffix = "amazonaws.com", reverse_dns_prefix = "com.amazonaws" }
}
variables {
  environment        = "dev"
  github_repository  = "offline/eks-platform-reference"
  github_environment = "dev-plan"
  oidc_provider_arn  = "arn:aws:iam::111122223333:oidc-provider/token.actions.githubusercontent.com"
  role_name          = "offline-dev-plan"
  cluster_name       = "offline-dev"
  state_bucket_arn   = "arn:aws:s3:::offline-eks-reference-state"
  state_prefix       = "environments/dev/"
  read_only          = true
  hosted_zone_id     = "ZOFFLINETEST"
}
run "plan_role_trust" {
  command = plan
  module { source = "../modules/pipeline" }
  assert {
    condition = (
      length(jsondecode(aws_iam_role.this.assume_role_policy).Statement) == 1 &&
      jsondecode(aws_iam_role.this.assume_role_policy).Statement[0].Effect == "Allow" &&
      jsondecode(aws_iam_role.this.assume_role_policy).Statement[0].Action == "sts:AssumeRoleWithWebIdentity" &&
      jsondecode(aws_iam_role.this.assume_role_policy).Statement[0].Principal.Federated == var.oidc_provider_arn &&
      jsondecode(aws_iam_role.this.assume_role_policy).Statement[0].Condition == {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          "token.actions.githubusercontent.com:sub" = "repo:offline/eks-platform-reference:environment:dev-plan"
        }
      }
    )
    error_message = "The actual plan role must trust only the exact GitHub environment, audience and provider."
  }
}
run "apply_role_trust" {
  command = plan
  module { source = "../modules/pipeline" }
  variables {
    github_environment = "dev"
    role_name          = "offline-dev-apply"
    read_only          = false
  }
  assert {
    condition = (
      length(jsondecode(aws_iam_role.this.assume_role_policy).Statement) == 1 &&
      jsondecode(aws_iam_role.this.assume_role_policy).Statement[0].Effect == "Allow" &&
      jsondecode(aws_iam_role.this.assume_role_policy).Statement[0].Action == "sts:AssumeRoleWithWebIdentity" &&
      jsondecode(aws_iam_role.this.assume_role_policy).Statement[0].Principal.Federated == var.oidc_provider_arn &&
      jsondecode(aws_iam_role.this.assume_role_policy).Statement[0].Condition == {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          "token.actions.githubusercontent.com:sub" = "repo:offline/eks-platform-reference:environment:dev"
        }
      }
    )
    error_message = "The actual apply role must trust only the exact GitHub environment, audience and provider."
  }
}
