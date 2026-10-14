provider "aws" {
  region = local.settings.region
  default_tags { tags = { environment = terraform.workspace, "managed-by" = "terraform", project = "eks-platform-reference" } }
}
data "aws_eks_cluster" "this" { name = local.settings.cluster_name }
provider "helm" {
  kubernetes = {
    host                   = data.aws_eks_cluster.this.endpoint
    cluster_ca_certificate = base64decode(data.aws_eks_cluster.this.certificate_authority[0].data)
    exec = {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", local.settings.cluster_name, "--region", local.settings.region]
    }
  }
}
provider "kubernetes" {
  host                   = data.aws_eks_cluster.this.endpoint
  cluster_ca_certificate = base64decode(data.aws_eks_cluster.this.certificate_authority[0].data)
  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", local.settings.cluster_name, "--region", local.settings.region]
  }
}
data "aws_route53_zone" "public" {
  zone_id      = local.settings.hosted_zone_id
  private_zone = false
  lifecycle {
    postcondition {
      condition     = !self.private_zone && lower(trimsuffix(self.name, ".")) == lower(trimsuffix(local.settings.domain_name, "."))
      error_message = "The selected hosted zone must be public and match domain_name."
    }
  }
}
data "aws_iam_role" "controller" { name = "${local.settings.cluster_name}-alb" }
data "aws_subnets" "public" {
  filter {
    name   = "vpc-id"
    values = [data.aws_eks_cluster.this.vpc_config[0].vpc_id]
  }
  filter {
    name   = "tag:kubernetes.io/role/elb"
    values = ["1"]
  }
}
module "observability" {
  region                    = local.settings.region
  cluster_name              = local.settings.cluster_name
  vpc_id                    = data.aws_eks_cluster.this.vpc_config[0].vpc_id
  public_subnet_ids         = data.aws_subnets.public.ids
  controller_role_arn       = data.aws_iam_role.controller.arn
  controller_chart_version  = local.settings.controller_chart_version
  hosted_zone_id            = data.aws_route53_zone.public.zone_id
  grafana_hostname          = local.settings.grafana_hostname
  load_balancer_name        = local.settings.load_balancer_name
  ingress_cidrs             = local.settings.ingress_cidrs
  source                    = "../../modules/observability"
  environment               = terraform.workspace
  chart_version             = local.settings.chart_version
  namespace                 = local.settings.namespace
  prometheus_retention      = local.settings.prometheus_retention
  prometheus_storage_size   = local.settings.prometheus_storage_size
  grafana_storage_size      = local.settings.grafana_storage_size
  prometheus_memory_request = local.settings.prometheus_memory_request
  prometheus_memory_limit   = local.settings.prometheus_memory_limit
}
