# RBAC for kube-state-metrics (infra/k3s-apps' own
# modules/node_exporter, which despite the module name also holds
# kube-state-metrics -- see that module's own main.tf comment for why
# the two are paired). Same reasoning as dashboard_rbac.tf above:
# granting RBAC is itself privilege-defining, so the ServiceAccount and
# its ClusterRoleBinding have to live in this rare/admin root, not in
# k3s-apps' own CI-applied one. The actual application resources
# (Deployment, Service) stay in k3s-apps, which only ever references
# this ServiceAccount by name in a Pod spec -- that alone needs no RBAC
# grant over the ServiceAccount object itself.
#
# Bound to the built-in "view" ClusterRole rather than the upstream
# bespoke one, plus kube_state_metrics_cluster_read below: "view" only
# covers namespaced resources, and kube-state-metrics' --resources flag
# (k3s-apps) also lists nodes, persistentvolumes and namespaces. Secrets
# stay excluded on both sides.

resource "kubernetes_service_account_v1" "kube_state_metrics" {
  metadata {
    name      = "kube-state-metrics"
    namespace = "default"
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
    name      = kubernetes_service_account_v1.kube_state_metrics.metadata[0].name
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
    namespace = "default"
  }
}
