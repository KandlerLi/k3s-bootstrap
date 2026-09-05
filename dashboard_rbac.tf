# RBAC for the Kubernetes Dashboard (infra/k3s-apps' own
# modules/kubernetes_dashboard), same reasoning as storage.tf above and
# the k3s_apps_ci Role in main.tf: granting RBAC objects is itself
# privilege-defining, so the ServiceAccount, its own operational
# Role/RoleBinding, and the read-only ClusterRoleBinding all have to
# live in this rare/admin root, not in k3s-apps' own CI-applied one --
# a CI ServiceAccount that could create ServiceAccounts or
# (Cluster)RoleBindings could grant itself, or anything it deploys,
# arbitrary privilege up to and including cluster-admin. The
# Dashboard's actual application resources (Deployment, Service) stay
# in k3s-apps, which only ever references this ServiceAccount by name
# in a Pod spec -- that alone needs no RBAC grant over the
# ServiceAccount object itself.
#
# Deliberately bound to the built-in "view" ClusterRole, not the
# cluster-admin the official recommended.yaml manifest defaults to --
# confirmed with Julian: read-only for now. "view" is a real
# Kubernetes-shipped aggregated ClusterRole (every cluster has it),
# covering get/list/watch on almost everything cluster-wide except
# Secrets' own contents and RBAC objects themselves -- enough to browse
# every workload/node/event in the UI, nothing that can change cluster
# state even if the Basic Auth in front of it (modules/ingress's own
# k8s.jkandler.de router) were ever bypassed.

resource "kubernetes_service_account_v1" "kubernetes_dashboard" {
  metadata {
    name      = "kubernetes-dashboard"
    namespace = "default"
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
    namespace = "default"
  }
}

# The Dashboard's own narrow operational permissions -- managing its
# own key-holder/CSRF Secrets and settings ConfigMap, exactly the scope
# the official recommended.yaml grants, just namespaced to "default"
# (this cluster's one namespace) instead of a dedicated
# kubernetes-dashboard namespace. Both Secrets/the ConfigMap start out
# nonexistent -- Dashboard creates them itself on first run, hence the
# separate unscoped "create" rules below (RBAC resourceNames can only
# restrict verbs against objects that already exist).
resource "kubernetes_role_v1" "kubernetes_dashboard" {
  metadata {
    name      = "kubernetes-dashboard"
    namespace = "default"
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
    namespace = "default"
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role_v1.kubernetes_dashboard.metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account_v1.kubernetes_dashboard.metadata[0].name
    namespace = "default"
  }
}

# Cluster-wide read access to node/pod resource-usage metrics, feeding
# the small CPU/Memory numbers on the Dashboard's own Node/Pod/Overview
# pages -- inert, not an error, if this cluster has no metrics-server
# actually serving the metrics.k8s.io API. Independent of the
# metrics-scraper sidecar (the historical usage-graph feature) that
# infra/k3s-apps' own modules/kubernetes_dashboard deliberately leaves
# out of its first cut -- see that module's own main.tf comment.
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
    namespace = "default"
  }
}
