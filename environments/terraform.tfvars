environments = {
  dev = {
    region       = "us-east-1"
    cluster_name = "eks-platform-reference-dev"
    vpc_cidr     = "10.20.0.0/16"
    subnets = {
      a = { availability_zone = "us-east-1a", public_cidr = "10.20.0.0/24", private_cidr = "10.20.16.0/20" }
      b = { availability_zone = "us-east-1b", public_cidr = "10.20.1.0/24", private_cidr = "10.20.32.0/20" }
    }
    single_nat_gateway = true
    internet_cidr      = "0.0.0.0/0"
    kubernetes_version = "1.35"
    # GitHub-hosted runners have changing IPs. Use restricted CIDRs with a fixed-egress runner.
    public_access_cidrs = ["0.0.0.0/0"]
    instance_types      = ["t3.medium"]
    node_sizes          = { min = 2, desired = 2, max = 3 }
    node_disk_size      = 30
    log_retention_days  = 7
    deploy_role_name    = "github-eks-platform-dev-apply"
    plan_role_name      = "github-eks-platform-dev-plan"
    administrator_arns = {
      patrick = "arn:aws:iam::626193791566:user/patrick"
    }
  }

  prod = {
    region       = "us-east-1"
    cluster_name = "eks-platform-reference-prod"
    vpc_cidr     = "10.30.0.0/16"
    subnets = {
      a = { availability_zone = "us-east-1a", public_cidr = "10.30.0.0/24", private_cidr = "10.30.16.0/20" }
      b = { availability_zone = "us-east-1b", public_cidr = "10.30.1.0/24", private_cidr = "10.30.32.0/20" }
      c = { availability_zone = "us-east-1c", public_cidr = "10.30.2.0/24", private_cidr = "10.30.48.0/20" }
    }
    single_nat_gateway = false
    internet_cidr      = "0.0.0.0/0"
    kubernetes_version = "1.35"
    # GitHub-hosted runners have changing IPs. Use restricted CIDRs with a fixed-egress runner.
    public_access_cidrs = ["0.0.0.0/0"]
    instance_types      = ["m6i.large"]
    node_sizes          = { min = 3, desired = 3, max = 6 }
    node_disk_size      = 30
    log_retention_days  = 30
    deploy_role_name    = "github-eks-platform-prod-apply"
    plan_role_name      = "github-eks-platform-prod-plan"
  }
}
