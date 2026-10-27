# view plus cluster-scoped reads, Secrets excluded: see README, "RBAC".

resource "kubernetes_service_account_v1" "kube_state_metrics" {
  metadata {
    name      = "kube-state-metrics"
    namespace = kubernetes_namespace_v1.monitoring.metadata[0].name
  }
}

# The Deployment's old identity until k3s-apps has moved it to monitoring; removed afterwards.
resource "kubernetes_service_account_v1" "kube_state_metrics_default" {
  metadata {
    name      = "kube-state-metrics"
    namespace = "default"
  }
}

moved {
  from = kubernetes_service_account_v1.kube_state_metrics
  to   = kubernetes_service_account_v1.kube_state_metrics_default
}

resource "kubernetes_cluster_role_binding_v1" "kube_state_metrics_view" {
  metadata {
    name = "kube-state-metrics-view"
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = "view"
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account_v1.kube_state_metrics.metadata[0].name
    namespace = kubernetes_service_account_v1.kube_state_metrics.metadata[0].namespace
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account_v1.kube_state_metrics_default.metadata[0].name
    namespace = "default"
  }
}

resource "kubernetes_cluster_role_v1" "kube_state_metrics_cluster_read" {
  metadata {
    name = "kube-state-metrics-cluster-read"
  }

  rule {
    api_groups = [""]
    resources  = ["nodes", "persistentvolumes", "namespaces"]
    verbs      = ["list", "watch"]
  }
}

resource "kubernetes_cluster_role_binding_v1" "kube_state_metrics_cluster_read" {
  metadata {
    name = "kube-state-metrics-cluster-read"
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role_v1.kube_state_metrics_cluster_read.metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account_v1.kube_state_metrics.metadata[0].name
    namespace = kubernetes_service_account_v1.kube_state_metrics.metadata[0].namespace
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account_v1.kube_state_metrics_default.metadata[0].name
    namespace = "default"
  }
}
