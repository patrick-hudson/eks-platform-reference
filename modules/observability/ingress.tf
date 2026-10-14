
resource "helm_release" "load_balancer_controller" {
  name       = "aws-load-balancer-controller"
  namespace  = "kube-system"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  version    = var.controller_chart_version
  atomic     = true
  wait       = true
  timeout    = 600
  values = [yamlencode({
    clusterName  = var.cluster_name
    region       = var.region
    vpcId        = var.vpc_id
    replicaCount = 2
    defaultTags  = local.labels
    serviceAccount = {
      create      = true
      name        = "aws-load-balancer-controller"
      annotations = { "eks.amazonaws.com/role-arn" = var.controller_role_arn }
    }
  })]
}
resource "aws_acm_certificate" "grafana" {
  domain_name       = var.grafana_hostname
  validation_method = "DNS"
  tags              = local.labels
  lifecycle { create_before_destroy = true }
}
resource "aws_route53_record" "validation" {
  for_each = {
    for option in aws_acm_certificate.grafana.domain_validation_options : option.domain_name => {
      name  = option.resource_record_name
      type  = option.resource_record_type
      value = option.resource_record_value
    }
  }
  zone_id = var.hosted_zone_id
  name    = each.value.name
  type    = each.value.type
  ttl     = 60
  records = [each.value.value]
}
resource "aws_acm_certificate_validation" "grafana" {
  certificate_arn         = aws_acm_certificate.grafana.arn
  validation_record_fqdns = [for record in aws_route53_record.validation : record.fqdn]
}
resource "kubernetes_ingress_v1" "grafana" {
  wait_for_load_balancer = true
  metadata {
    name      = "grafana"
    namespace = kubernetes_namespace_v1.monitoring.metadata[0].name
    labels    = local.labels
    annotations = {
      "alb.ingress.kubernetes.io/scheme"             = "internet-facing"
      "alb.ingress.kubernetes.io/target-type"        = "ip"
      "alb.ingress.kubernetes.io/load-balancer-name" = var.load_balancer_name
      "alb.ingress.kubernetes.io/subnets"            = join(",", var.public_subnet_ids)
      "alb.ingress.kubernetes.io/inbound-cidrs"      = join(",", var.ingress_cidrs)
      "alb.ingress.kubernetes.io/listen-ports"       = jsonencode([{ HTTP = 80 }, { HTTPS = 443 }])
      "alb.ingress.kubernetes.io/ssl-redirect"       = "443"
      "alb.ingress.kubernetes.io/ssl-policy"         = "ELBSecurityPolicy-TLS13-1-2-2021-06"
      "alb.ingress.kubernetes.io/certificate-arn"    = aws_acm_certificate_validation.grafana.certificate_arn
      "alb.ingress.kubernetes.io/healthcheck-path"   = "/api/health"
      "alb.ingress.kubernetes.io/tags"               = join(",", [for key, value in local.labels : "${key}=${value}"])
    }
  }
  spec {
    ingress_class_name = "alb"
    rule {
      host = var.grafana_hostname
      http {
        path {
          path      = "/"
          path_type = "Prefix"
          backend {
            service {
              name = "${helm_release.monitoring.name}-grafana"
              port { number = 80 }
            }
          }
        }
      }
    }
  }
  depends_on = [helm_release.load_balancer_controller]
}
# The controller owns the ALB; Terraform reads it after the ingress receives its hostname.
data "aws_lb" "grafana" {
  name       = var.load_balancer_name
  depends_on = [kubernetes_ingress_v1.grafana]
}
resource "aws_route53_record" "grafana" {
  zone_id = var.hosted_zone_id
  name    = var.grafana_hostname
  type    = "A"
  alias {
    name                   = data.aws_lb.grafana.dns_name
    zone_id                = data.aws_lb.grafana.zone_id
    evaluate_target_health = true
  }
}
