locals {
  labels = merge(var.tags, { environment = var.environment, "managed-by" = "terraform", project = "eks-platform-reference" })
}
resource "helm_release" "monitoring" {
  name             = "monitoring"
  namespace        = var.namespace
  create_namespace = false
  repository       = "https://prometheus-community.github.io/helm-charts"
  chart            = "kube-prometheus-stack"
  version          = var.chart_version
  atomic           = true
  cleanup_on_fail  = true
  timeout          = 900
  wait             = true
  depends_on       = [kubernetes_namespace_v1.monitoring]
  values = [yamlencode({
    commonLabels = local.labels
    # EKS does not expose these managed control-plane scrape targets.
    kubeEtcd              = { enabled = false }
    kubeControllerManager = { enabled = false }
    kubeScheduler         = { enabled = false }
    kubeProxy             = { enabled = false }
    defaultRules          = { rules = { etcd = false, kubeControllerManager = false, kubeSchedulerAlerting = false, kubeSchedulerRecording = false, kubeProxy = false } }
    alertmanager          = { enabled = false }
    grafana = {
      # Grafana's chart generates its own password; no password in tfvars or Helm values.
      adminPassword = null
      "grafana.ini" = {
        server           = { domain = var.grafana_hostname, root_url = "https://${var.grafana_hostname}" }
        users            = { allow_sign_up = false }
        "auth.anonymous" = { enabled = false }
        security         = { cookie_secure = true, cookie_samesite = "lax" }
      }
      service     = { type = "ClusterIP" }
      persistence = { enabled = true, storageClassName = kubernetes_storage_class_v1.monitoring.metadata[0].name, size = var.grafana_storage_size }
      resources   = { requests = { cpu = "100m", memory = "128Mi" }, limits = { memory = "512Mi" } }
      podLabels   = local.labels
    }
    prometheus = {
      service = { type = "ClusterIP" }
      prometheusSpec = {
        retention      = var.prometheus_retention
        retentionSize  = "${floor(tonumber(trimsuffix(var.prometheus_storage_size, "Gi")) * 0.8)}GB"
        externalLabels = local.labels
        podMetadata    = { labels = local.labels }
        resources      = { requests = { cpu = "200m", memory = var.prometheus_memory_request }, limits = { memory = var.prometheus_memory_limit } }
        storageSpec = { volumeClaimTemplate = { spec = {
          storageClassName = kubernetes_storage_class_v1.monitoring.metadata[0].name
          accessModes      = ["ReadWriteOnce"]
          resources        = { requests = { storage = var.prometheus_storage_size } }
        } } }
      }
    }
  })]
}

resource "kubernetes_namespace_v1" "monitoring" {
  metadata {
    name   = var.namespace
    labels = local.labels
  }
}
resource "kubernetes_storage_class_v1" "monitoring" {
  metadata {
    name   = "monitoring-gp3"
    labels = local.labels
  }
  storage_provisioner    = "ebs.csi.aws.com"
  reclaim_policy         = "Delete"
  volume_binding_mode    = "WaitForFirstConsumer"
  allow_volume_expansion = true
  parameters = merge({ type = "gp3", encrypted = "true" }, {
    for i, k in sort(keys(local.labels)) : "tagSpecification_${i + 1}" => "${k}=${local.labels[k]}"
  })
}
