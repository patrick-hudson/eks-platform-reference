variable "test_workspace" { type = string }
variable "environments" { type = any }
provider "aws" {
  region                      = var.environments[var.test_workspace].region
  access_key                  = "offline-testing"
  secret_key                  = "offline-testing"
  skip_credentials_validation = true
  skip_requesting_account_id  = true
  skip_metadata_api_check     = true
}
mock_provider "helm" {}
mock_provider "kubernetes" {}
override_data {
  target = data.aws_eks_cluster.this
  values = {
    endpoint              = "https://offline.invalid"
    certificate_authority = [{ data = "dGVzdA==" }]
    vpc_config            = [{ vpc_id = "vpc-offline", subnet_ids = ["subnet-offline-a", "subnet-offline-b"], cluster_security_group_id = "sg-offline", security_group_ids = [], endpoint_private_access = true, endpoint_public_access = true, public_access_cidrs = [] }]
  }
}
override_data {
  target = data.aws_route53_zone.public
  values = { zone_id = "ZOFFLINETEST", name = "hudson.tf", private_zone = false }
}
override_data {
  target = data.aws_iam_role.controller
  values = { arn = "arn:aws:iam::111122223333:role/offline-alb" }
}
override_data {
  target = data.aws_subnets.public
  values = { ids = ["subnet-offline-a", "subnet-offline-b"] }
}
override_data {
  target = module.observability.data.aws_lb.grafana
  values = { dns_name = "offline.elb.amazonaws.com", zone_id = "ZOFFLINEALB" }
}
run "monitoring_plan" {
  command = plan
  assert {
    condition     = output.grafana_service == "monitoring-grafana"
    error_message = "Ingress and the documented password lookup must address the chart's Grafana service."
  }
  assert {
    condition     = output.grafana_url == "https://${var.environments[var.test_workspace].grafana_hostname}"
    error_message = "Grafana output must use the configured HTTPS hostname."
  }
}

run "reject_incorrect_hosted_zone" {
  command = plan
  override_data {
    target = data.aws_route53_zone.public
    values = { zone_id = "ZOFFLINETEST", name = "other.invalid", private_zone = false }
  }
  expect_failures = [data.aws_route53_zone.public]
}
