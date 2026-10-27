# Dashboard RBAC, read-only and never cluster-admin: see README, "RBAC".

resource "kubernetes_service_account_v1" "kubernetes_dashboard" {
  metadata {
    name      = "kubernetes-dashboard"
    namespace = kubernetes_namespace_v1.apps.metadata[0].name
  }
}

resource "kubernetes_cluster_role_binding_v1" "kubernetes_dashboard_view" {
  metadata {
    name = "kubernetes-dashboard-view"
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = "view"
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account_v1.kubernetes_dashboard.metadata[0].name
    namespace = kubernetes_namespace_v1.apps.metadata[0].name
  }
}

resource "kubernetes_cluster_role_v1" "kubernetes_dashboard_cluster_read" {
  metadata {
    name = "kubernetes-dashboard-cluster-read"
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

resource "kubernetes_cluster_role_binding_v1" "kubernetes_dashboard_cluster_read" {
  metadata {
    name = "kubernetes-dashboard-cluster-read"
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role_v1.kubernetes_dashboard_cluster_read.metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account_v1.kubernetes_dashboard.metadata[0].name
    namespace = kubernetes_namespace_v1.apps.metadata[0].name
  }
}

# Its own Secrets and ConfigMap; create can't be name-scoped since they don't exist yet.
resource "kubernetes_role_v1" "kubernetes_dashboard" {
  metadata {
    name      = "kubernetes-dashboard"
    namespace = kubernetes_namespace_v1.apps.metadata[0].name
  }

  rule {
    api_groups     = [""]
    resources      = ["secrets"]
    resource_names = ["kubernetes-dashboard-key-holder", "kubernetes-dashboard-csrf"]
    verbs          = ["get", "update", "delete"]
  }
  rule {
    api_groups = [""]
    resources  = ["secrets"]
    verbs      = ["create"]
  }
  rule {
    api_groups     = [""]
    resources      = ["configmaps"]
    resource_names = ["kubernetes-dashboard-settings"]
    verbs          = ["get", "update"]
  }
  rule {
    api_groups = [""]
    resources  = ["configmaps"]
    verbs      = ["create"]
  }
}

resource "kubernetes_role_binding_v1" "kubernetes_dashboard" {
  metadata {
    name      = "kubernetes-dashboard"
    namespace = kubernetes_namespace_v1.apps.metadata[0].name
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role_v1.kubernetes_dashboard.metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account_v1.kubernetes_dashboard.metadata[0].name
    namespace = kubernetes_namespace_v1.apps.metadata[0].name
  }
}

# Usage metrics for the Dashboard's CPU/memory numbers; inert without metrics-server.
resource "kubernetes_cluster_role_v1" "kubernetes_dashboard_metrics" {
  metadata {
    name = "kubernetes-dashboard-metrics"
  }

  rule {
    api_groups = ["metrics.k8s.io"]
    resources  = ["pods", "nodes"]
    verbs      = ["get", "list", "watch"]
  }
}

resource "kubernetes_cluster_role_binding_v1" "kubernetes_dashboard_metrics" {
  metadata {
    name = "kubernetes-dashboard-metrics"
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role_v1.kubernetes_dashboard_metrics.metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account_v1.kubernetes_dashboard.metadata[0].name
    namespace = kubernetes_namespace_v1.apps.metadata[0].name
  }
}
