provider "aws" {
  region = local.settings.region
  default_tags { tags = { environment = terraform.workspace, "managed-by" = "terraform", project = "eks-platform-reference" } }
}
data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}
module "network" {
  source             = "../modules/network"
  environment        = terraform.workspace
  name               = local.settings.cluster_name
  vpc_cidr           = local.settings.vpc_cidr
  subnets            = local.settings.subnets
  single_nat_gateway = local.settings.single_nat_gateway
  internet_cidr      = local.settings.internet_cidr
}
module "cluster" {
  source              = "../modules/cluster"
  environment         = terraform.workspace
  cluster_name        = local.settings.cluster_name
  kubernetes_version  = local.settings.kubernetes_version
  subnet_ids          = module.network.private_subnet_ids
  public_access_cidrs = local.settings.public_access_cidrs
  instance_types      = local.settings.instance_types
  node_sizes          = local.settings.node_sizes
  node_disk_size      = local.settings.node_disk_size
  log_retention_days  = local.settings.log_retention_days
  access_entries = merge({
    deploy = { principal_arn = "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:role/${local.settings.deploy_role_name}", policy_name = "AmazonEKSClusterAdminPolicy" }
    plan   = { principal_arn = "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:role/${local.settings.plan_role_name}", policy_name = "AmazonEKSAdminViewPolicy" }
  }, { for name, arn in local.settings.administrator_arns : "admin-${name}" => { principal_arn = arn, policy_name = "AmazonEKSClusterAdminPolicy" } })
  # Route tables must be ready before nodes need outbound access.
  depends_on = [module.network]
}
