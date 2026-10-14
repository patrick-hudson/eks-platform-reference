provider "aws" {
  region = var.region
  default_tags { tags = { environment = "bootstrap", "managed-by" = "terraform", project = "eks-platform-reference" } }
}
resource "aws_s3_bucket" "state" {
  bucket = var.state_bucket_name
  lifecycle { prevent_destroy = true }
}
resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id
  versioning_configuration { status = "Enabled" }
}
resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}
resource "aws_s3_bucket_public_access_block" "state" {
  bucket                  = aws_s3_bucket.state.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}
data "aws_iam_policy_document" "state" {
  statement {
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.state.arn, "${aws_s3_bucket.state.arn}/*"]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}
resource "aws_s3_bucket_policy" "state" {
  bucket = aws_s3_bucket.state.id
  policy = data.aws_iam_policy_document.state.json
}
resource "aws_iam_openid_connect_provider" "github" {
  count          = var.github_oidc_provider_arn == null ? 1 : 0
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
}
data "aws_route53_zone" "public" {
  zone_id      = var.hosted_zone_id
  private_zone = false
  lifecycle {
    postcondition {
      condition     = !self.private_zone && lower(trimsuffix(self.name, ".")) == lower(trimsuffix(var.domain_name, "."))
      error_message = "The selected hosted zone must be public and match domain_name."
    }
  }
}
locals {
  github_oidc_provider_arn = var.github_oidc_provider_arn != null ? var.github_oidc_provider_arn : aws_iam_openid_connect_provider.github[0].arn
  roles = merge(
    { for env, config in var.environments : "${env}-apply" => { environment = env, github_environment = env, role_name = config.deploy_role_name, cluster_name = config.cluster_name, read_only = false } },
    { for env, config in var.environments : "${env}-plan" => { environment = env, github_environment = "${env}-plan", role_name = config.plan_role_name, cluster_name = config.cluster_name, read_only = true } }
  )
}
module "pipeline" {
  for_each           = local.roles
  source             = "../modules/pipeline"
  environment        = each.value.environment
  github_repository  = var.github_repository
  github_environment = each.value.github_environment
  oidc_provider_arn  = local.github_oidc_provider_arn
  role_name          = each.value.role_name
  cluster_name       = each.value.cluster_name
  region             = var.region
  state_bucket_arn   = aws_s3_bucket.state.arn
  state_prefix       = "environments/${each.value.environment}/"
  hosted_zone_id     = data.aws_route53_zone.public.zone_id
  read_only          = each.value.read_only
}
