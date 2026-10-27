# view plus cluster-scoped reads, Secrets excluded: see README, "RBAC".

resource "kubernetes_service_account_v1" "kube_state_metrics_monitoring" {
  metadata {
    name      = "kube-state-metrics"
    namespace = kubernetes_namespace_v1.monitoring.metadata[0].name
  }
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
    name      = kubernetes_service_account_v1.kube_state_metrics_monitoring.metadata[0].name
    namespace = kubernetes_service_account_v1.kube_state_metrics_monitoring.metadata[0].namespace
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
    name      = kubernetes_service_account_v1.kube_state_metrics_monitoring.metadata[0].name
    namespace = kubernetes_service_account_v1.kube_state_metrics_monitoring.metadata[0].namespace
  }
}
