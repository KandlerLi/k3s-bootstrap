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
# Bound to the same built-in "view" ClusterRole as
# kubernetes-dashboard, not kube-state-metrics' own upstream RBAC
# manifest (a much longer bespoke ClusterRole covering ~20 resource
# types) -- "view" already covers get/list/watch on everything
# kube-state-metrics needs for per-node/per-workload resource-request-
# vs-actual reporting (pods, nodes, deployments, replicasets,
# daemonsets, statefulsets, jobs, cronjobs, services, namespaces,
# persistentvolumeclaims, persistentvolumes), while still excluding
# Secrets and RBAC objects themselves -- reusing it means one fewer
# bespoke ClusterRole to keep correct over time, at the cost of
# kube-state-metrics' own Secret-related metrics never being collected
# (deliberately excluded from its own --resources flag in k3s-apps'
# module to match what this binding actually grants).

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
