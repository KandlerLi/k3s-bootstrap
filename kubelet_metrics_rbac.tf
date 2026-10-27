# Prometheus on the homeserver scrapes kubelet's cAdvisor endpoint with this token: see README, "RBAC".

resource "kubernetes_service_account_v1" "prometheus_kubelet" {
  metadata {
    name      = "prometheus-kubelet"
    namespace = "default"
  }
}

# nodes/metrics only; nodes/proxy would also allow exec into every Pod.
resource "kubernetes_cluster_role_v1" "kubelet_metrics_read" {
  metadata {
    name = "kubelet-metrics-read"
  }

  rule {
    api_groups = [""]
    resources  = ["nodes/metrics"]
    verbs      = ["get"]
  }
}

resource "kubernetes_cluster_role_binding_v1" "prometheus_kubelet" {
  metadata {
    name = "prometheus-kubelet"
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role_v1.kubelet_metrics_read.metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account_v1.prometheus_kubelet.metadata[0].name
    namespace = "default"
  }
}

# Long-lived, since Prometheus runs outside the cluster; rotate with -replace.
resource "kubernetes_secret_v1" "prometheus_kubelet_token" {
  metadata {
    name      = "prometheus-kubelet-token"
    namespace = "default"
    annotations = {
      "kubernetes.io/service-account.name" = kubernetes_service_account_v1.prometheus_kubelet.metadata[0].name
    }
  }

  type                           = "kubernetes.io/service-account-token"
  wait_for_service_account_token = true
}
