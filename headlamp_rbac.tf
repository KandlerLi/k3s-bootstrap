# Headlamp RBAC, read-only and never cluster-admin: see README, "RBAC".

resource "kubernetes_service_account_v1" "headlamp" {
  metadata {
    name      = "headlamp"
    namespace = kubernetes_namespace_v1.apps.metadata[0].name
  }
}

resource "kubernetes_cluster_role_binding_v1" "headlamp_view" {
  metadata {
    name = "headlamp-view"
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = "view"
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account_v1.headlamp.metadata[0].name
    namespace = kubernetes_namespace_v1.apps.metadata[0].name
  }
}

resource "kubernetes_cluster_role_v1" "headlamp_cluster_read" {
  metadata {
    name = "headlamp-cluster-read"
  }

  rule {
    api_groups = [""]
    resources  = ["nodes", "persistentvolumes", "namespaces"]
    verbs      = ["get", "list", "watch"]
  }

  rule {
    api_groups = ["storage.k8s.io"]
    resources  = ["storageclasses", "csidrivers", "csinodes", "volumeattachments"]
    verbs      = ["get", "list", "watch"]
  }

  rule {
    api_groups = ["rbac.authorization.k8s.io"]
    resources  = ["roles", "rolebindings", "clusterroles", "clusterrolebindings"]
    verbs      = ["get", "list", "watch"]
  }

  rule {
    api_groups = ["networking.k8s.io"]
    resources  = ["ingressclasses"]
    verbs      = ["get", "list", "watch"]
  }

  rule {
    api_groups = ["apiextensions.k8s.io"]
    resources  = ["customresourcedefinitions"]
    verbs      = ["get", "list", "watch"]
  }
}

resource "kubernetes_cluster_role_binding_v1" "headlamp_cluster_read" {
  metadata {
    name = "headlamp-cluster-read"
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role_v1.headlamp_cluster_read.metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account_v1.headlamp.metadata[0].name
    namespace = kubernetes_namespace_v1.apps.metadata[0].name
  }
}

# Usage metrics for Headlamp's CPU/memory numbers (k3s' metrics-server).
resource "kubernetes_cluster_role_v1" "headlamp_metrics" {
  metadata {
    name = "headlamp-metrics"
  }

  rule {
    api_groups = ["metrics.k8s.io"]
    resources  = ["pods", "nodes"]
    verbs      = ["get", "list", "watch"]
  }
}

resource "kubernetes_cluster_role_binding_v1" "headlamp_metrics" {
  metadata {
    name = "headlamp-metrics"
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role_v1.headlamp_metrics.metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account_v1.headlamp.metadata[0].name
    namespace = kubernetes_namespace_v1.apps.metadata[0].name
  }
}
