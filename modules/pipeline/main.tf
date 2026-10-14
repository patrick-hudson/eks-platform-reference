data "aws_partition" "current" {}
data "aws_caller_identity" "current" {}
locals {
  tags             = merge(var.tags, { environment = var.environment, "managed-by" = "terraform", project = "eks-platform-reference" })
  cluster_role_arn = "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:role/${var.cluster_name}-*"
}
data "aws_iam_policy_document" "trust" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [var.oidc_provider_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${var.github_repository}:environment:${var.github_environment}"]
    }
  }
}
resource "aws_iam_role" "this" {
  name                 = var.role_name
  assume_role_policy   = data.aws_iam_policy_document.trust.json
  max_session_duration = 3600
  tags                 = local.tags
}
data "aws_iam_policy_document" "permissions" {
  statement {
    sid       = "StateBucket"
    actions   = ["s3:ListBucket"]
    resources = [var.state_bucket_arn]
    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values   = ["environments/", "${var.state_prefix}*"]
    }
  }
  statement {
    sid       = "StateObjects"
    actions   = var.read_only ? ["s3:GetObject"] : ["s3:GetObject", "s3:PutObject"]
    resources = ["${var.state_bucket_arn}/${var.state_prefix}*"]
  }
  dynamic "statement" {
    for_each = var.read_only ? [] : [1]
    content {
      sid       = "StateLockFiles"
      actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
      resources = ["${var.state_bucket_arn}/${var.state_prefix}*.tflock"]
    }
  }
  statement {
    sid       = "RegionalServices"
    actions   = var.read_only ? ["ec2:Describe*", "eks:Describe*", "eks:List*", "logs:Describe*", "logs:ListTagsForResource", "autoscaling:Describe*", "elasticloadbalancing:Describe*", "acm:DescribeCertificate", "acm:ListCertificates", "acm:ListTagsForCertificate"] : ["ec2:*", "eks:*", "logs:CreateLogGroup", "logs:DeleteLogGroup", "logs:PutRetentionPolicy", "logs:DeleteRetentionPolicy", "logs:Describe*", "logs:ListTagsForResource", "logs:TagResource", "logs:UntagResource", "autoscaling:Describe*", "autoscaling:CreateOrUpdateTags", "autoscaling:DeleteTags", "elasticloadbalancing:Describe*", "acm:RequestCertificate", "acm:DeleteCertificate", "acm:DescribeCertificate", "acm:ListCertificates", "acm:ListTagsForCertificate", "acm:AddTagsToCertificate", "acm:RemoveTagsFromCertificate"]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = [var.region]
    }
  }
  statement {
    sid       = "DNSRead"
    actions   = ["route53:ListHostedZones", "route53:ListHostedZonesByName"]
    resources = ["*"]
  }
  statement {
    sid       = "DNSZone"
    actions   = var.read_only ? ["route53:GetHostedZone", "route53:ListResourceRecordSets", "route53:ListTagsForResource"] : ["route53:GetHostedZone", "route53:ListResourceRecordSets", "route53:ListTagsForResource", "route53:ChangeResourceRecordSets"]
    resources = ["arn:${data.aws_partition.current.partition}:route53:::hostedzone/${var.hosted_zone_id}"]
  }
  statement {
    sid       = "DNSChangeStatus"
    actions   = ["route53:GetChange"]
    resources = ["arn:${data.aws_partition.current.partition}:route53:::change/*"]
  }
  statement {
    sid       = "IAMRead"
    actions   = ["iam:Get*", "iam:List*"]
    resources = ["*"]
  }
  dynamic "statement" {
    for_each = var.read_only ? [] : [1]
    content {
      sid       = "ClusterRoles"
      actions   = ["iam:CreateRole", "iam:DeleteRole", "iam:UpdateAssumeRolePolicy", "iam:AttachRolePolicy", "iam:DetachRolePolicy", "iam:TagRole", "iam:UntagRole", "iam:PutRolePolicy", "iam:DeleteRolePolicy"]
      resources = [local.cluster_role_arn]
    }
  }
  dynamic "statement" {
    for_each = var.read_only ? [] : [1]
    content {
      sid       = "PassClusterRoles"
      actions   = ["iam:PassRole"]
      resources = [local.cluster_role_arn]
      condition {
        test     = "StringEquals"
        variable = "iam:PassedToService"
        values   = ["eks.amazonaws.com", "ec2.amazonaws.com"]
      }
    }
  }
  dynamic "statement" {
    for_each = var.read_only ? [] : [1]
    content {
      sid       = "ClusterOIDC"
      actions   = ["iam:CreateOpenIDConnectProvider", "iam:DeleteOpenIDConnectProvider", "iam:TagOpenIDConnectProvider", "iam:UntagOpenIDConnectProvider", "iam:UpdateOpenIDConnectProviderThumbprint"]
      resources = ["arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:oidc-provider/oidc.eks.${var.region}.amazonaws.com/id/*"]
    }
  }
  dynamic "statement" {
    for_each = var.read_only ? [] : [1]
    content {
      sid       = "EKSServiceLinkedRoles"
      actions   = ["iam:CreateServiceLinkedRole"]
      resources = ["*"]
      condition {
        test     = "StringEquals"
        variable = "iam:AWSServiceName"
        values   = ["eks.amazonaws.com", "eks-nodegroup.amazonaws.com", "autoscaling.amazonaws.com"]
      }
    }
  }
}
resource "aws_iam_role_policy" "this" {
  name   = "terraform"
  role   = aws_iam_role.this.id
  policy = data.aws_iam_policy_document.permissions.json
}
