data "aws_partition" "current" {}
locals {
  tags        = merge(var.tags, { environment = var.environment, "managed-by" = "terraform", project = "eks-platform-reference" })
  oidc_issuer = replace(aws_iam_openid_connect_provider.this.url, "https://", "")
  partition   = data.aws_partition.current.partition
  irsa = {
    alb = { subject = "system:serviceaccount:kube-system:aws-load-balancer-controller", policy = null }
    cni = { subject = "system:serviceaccount:kube-system:aws-node", policy = "AmazonEKS_CNI_Policy" }
    ebs = { subject = "system:serviceaccount:kube-system:ebs-csi-controller-sa", policy = "service-role/AmazonEBSCSIDriverPolicy" }
  }
}
data "aws_iam_policy_document" "cluster_trust" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["eks.amazonaws.com"]
    }
  }
}
resource "aws_iam_role" "cluster" {
  name               = "${var.cluster_name}-cluster"
  assume_role_policy = data.aws_iam_policy_document.cluster_trust.json
  tags               = local.tags
}
resource "aws_iam_role_policy_attachment" "cluster" {
  role       = aws_iam_role.cluster.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/AmazonEKSClusterPolicy"
}
resource "aws_cloudwatch_log_group" "cluster" {
  name              = "/aws/eks/${var.cluster_name}/cluster"
  retention_in_days = var.log_retention_days
  tags              = local.tags
}
resource "aws_eks_cluster" "this" {
  name                      = var.cluster_name
  role_arn                  = aws_iam_role.cluster.arn
  version                   = var.kubernetes_version
  enabled_cluster_log_types = ["api", "audit", "authenticator", "controllerManager", "scheduler"]
  access_config {
    authentication_mode                         = "API"
    bootstrap_cluster_creator_admin_permissions = false
  }
  upgrade_policy { support_type = "STANDARD" }
  vpc_config {
    subnet_ids              = var.subnet_ids
    endpoint_private_access = true
    endpoint_public_access  = true
    public_access_cidrs     = var.public_access_cidrs
  }
  tags       = local.tags
  depends_on = [aws_iam_role_policy_attachment.cluster, aws_cloudwatch_log_group.cluster]
}
resource "aws_iam_openid_connect_provider" "this" {
  url            = aws_eks_cluster.this.identity[0].oidc[0].issuer
  client_id_list = ["sts.amazonaws.com"]
  tags           = local.tags
}
data "aws_iam_policy_document" "irsa" {
  for_each = local.irsa
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.this.arn]
    }
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_issuer}:sub"
      values   = [each.value.subject]
    }
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_issuer}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}
resource "aws_iam_role" "irsa" {
  for_each           = local.irsa
  name               = "${var.cluster_name}-${each.key}"
  assume_role_policy = data.aws_iam_policy_document.irsa[each.key].json
  tags               = local.tags
}
resource "aws_iam_role_policy_attachment" "irsa" {
  for_each   = { for k, v in local.irsa : k => v if v.policy != null }
  role       = aws_iam_role.irsa[each.key].name
  policy_arn = "arn:${local.partition}:iam::aws:policy/${each.value.policy}"
}
data "aws_iam_policy_document" "node_trust" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}
resource "aws_iam_role" "node" {
  name               = "${var.cluster_name}-node"
  assume_role_policy = data.aws_iam_policy_document.node_trust.json
  tags               = local.tags
}
resource "aws_iam_role_policy_attachment" "node" {
  for_each   = toset(["AmazonEKSWorkerNodePolicy", "AmazonEC2ContainerRegistryPullOnly"])
  role       = aws_iam_role.node.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/${each.key}"
}
resource "aws_launch_template" "node" {
  name_prefix = "${var.cluster_name}-"
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }
  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_size           = var.node_disk_size
      volume_type           = "gp3"
      encrypted             = true
      delete_on_termination = true
    }
  }
  dynamic "tag_specifications" {
    for_each = toset(["instance", "volume", "network-interface"])
    content {
      resource_type = tag_specifications.value
      tags          = local.tags
    }
  }
  tags = local.tags
}
data "aws_eks_addon_version" "this" {
  for_each           = toset(["vpc-cni", "coredns", "kube-proxy", "aws-ebs-csi-driver"])
  addon_name         = each.key
  kubernetes_version = var.kubernetes_version
  most_recent        = false
}
# CNI must have its IAM role before any node tries to bring up pod networking.
resource "aws_eks_addon" "cni" {
  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = "vpc-cni"
  addon_version               = data.aws_eks_addon_version.this["vpc-cni"].version
  service_account_role_arn    = aws_iam_role.irsa["cni"].arn
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "PRESERVE"
  tags                        = local.tags
  depends_on                  = [aws_iam_role_policy_attachment.irsa]
}
resource "aws_eks_node_group" "this" {
  cluster_name    = aws_eks_cluster.this.name
  node_group_name = "${var.cluster_name}-workers"
  node_role_arn   = aws_iam_role.node.arn
  subnet_ids      = var.subnet_ids
  instance_types  = var.instance_types
  ami_type        = "AL2023_x86_64_STANDARD"
  capacity_type   = "ON_DEMAND"
  launch_template {
    id      = aws_launch_template.node.id
    version = aws_launch_template.node.latest_version
  }
  scaling_config {
    min_size     = var.node_sizes.min
    desired_size = var.node_sizes.desired
    max_size     = var.node_sizes.max
  }
  update_config { max_unavailable = 1 }
  labels     = { environment = var.environment, "managed-by" = "terraform", project = "eks-platform-reference" }
  tags       = local.tags
  depends_on = [aws_iam_role_policy_attachment.node, aws_eks_addon.cni]
}
resource "aws_eks_addon" "this" {
  for_each                    = toset(["coredns", "kube-proxy", "aws-ebs-csi-driver"])
  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = each.key
  addon_version               = data.aws_eks_addon_version.this[each.key].version
  service_account_role_arn    = each.key == "aws-ebs-csi-driver" ? aws_iam_role.irsa["ebs"].arn : null
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "PRESERVE"
  tags                        = local.tags
  depends_on                  = [aws_eks_node_group.this, aws_iam_role_policy_attachment.irsa]
}
resource "aws_eks_access_entry" "this" {
  for_each      = var.access_entries
  cluster_name  = aws_eks_cluster.this.name
  principal_arn = each.value.principal_arn
  tags          = local.tags
}
resource "aws_eks_access_policy_association" "this" {
  for_each      = var.access_entries
  cluster_name  = aws_eks_cluster.this.name
  principal_arn = aws_eks_access_entry.this[each.key].principal_arn
  policy_arn    = "arn:${local.partition}:eks::aws:cluster-access-policy/${each.value.policy_name}"
  access_scope { type = "cluster" }
}

# Upstream v2.14.1 policy, kept in sync with the pinned Helm controller chart.
resource "aws_iam_role_policy" "load_balancer_controller" {
  name   = "load-balancer-controller"
  role   = aws_iam_role.irsa["alb"].id
  policy = replace(file("${path.module}/load-balancer-controller-policy.json"), "arn:aws:", "arn:${local.partition}:")
}
# EKS owns these resources, but does not propagate cluster/node-group tags to them.
resource "aws_ec2_tag" "cluster_security_group" {
  for_each    = local.tags
  resource_id = aws_eks_cluster.this.vpc_config[0].cluster_security_group_id
  key         = each.key
  value       = each.value
}
resource "aws_autoscaling_group_tag" "node" {
  for_each               = local.tags
  autoscaling_group_name = aws_eks_node_group.this.resources[0].autoscaling_groups[0].name
  tag {
    key                 = each.key
    value               = each.value
    propagate_at_launch = true
  }
}
