# Bootstrap root: the runner, cluster-scoped PVs and privilege-defining RBAC. See README.

# The runners' own namespace, the only one where privileged Pods (dind) are intended: see README, "Namespaces".
resource "kubernetes_namespace_v1" "ci" {
  metadata {
    name = "ci"
    labels = {
      "pod-security.kubernetes.io/enforce" = "privileged"
    }
  }
}

# node-exporter alone: it needs the host's network, PID namespace and filesystem. See README, "Namespaces".
resource "kubernetes_namespace_v1" "node_exporter" {
  metadata {
    name = "node-exporter"
    labels = {
      "pod-security.kubernetes.io/enforce" = "privileged"
    }
  }
}

# Grafana, Alertmanager and kube-state-metrics: see README, "Namespaces".
resource "kubernetes_namespace_v1" "monitoring" {
  metadata {
    name = "monitoring"
    labels = {
      "pod-security.kubernetes.io/enforce" = "baseline"
      "pod-security.kubernetes.io/warn"    = "restricted"
    }
  }
}

# Authelia: see README, "Namespaces".
resource "kubernetes_namespace_v1" "auth" {
  metadata {
    name = "auth"
    labels = {
      "pod-security.kubernetes.io/enforce" = "baseline"
      "pod-security.kubernetes.io/warn"    = "restricted"
    }
  }
}

# Every remaining k3s-apps workload, Traefik included: see README, "Namespaces".
resource "kubernetes_namespace_v1" "apps" {
  metadata {
    name = "apps"
    labels = {
      "pod-security.kubernetes.io/enforce" = "baseline"
      "pod-security.kubernetes.io/warn"    = "restricted"
    }
  }
}

module "github_runner" {
  source = "./modules/github_runner"

  namespace = kubernetes_namespace_v1.ci.metadata[0].name

  github_runner_app_id          = local.home_infra_github_runner["app_id"]
  github_runner_app_private_key = local.home_infra_github_runner["app_private_key"]
  github_runner_repositories    = var.github_runner_repositories

  github_runner_service_accounts = {
    k3s-apps = kubernetes_service_account_v1.k3s_apps_ci.metadata[0].name
  }
}

# The ServiceAccount k3s-apps' CI runs as: see README, "RBAC".
# In ci next to its runner Pod; its Role stays in default, where the apps live.
resource "kubernetes_service_account_v1" "k3s_apps_ci" {
  metadata {
    name      = "k3s-apps-ci"
    namespace = kubernetes_namespace_v1.ci.metadata[0].name
  }
}

resource "kubernetes_role_v1" "k3s_apps_ci" {
  metadata {
    name = "k3s-apps-ci"
  }

  rule {
    api_groups = [""]
    resources  = ["services", "configmaps", "secrets", "persistentvolumeclaims", "endpoints"]
    verbs      = ["get", "list", "watch", "create", "update", "patch", "delete"]
  }
  # daemonsets: for k3s-apps' node_exporter.
  rule {
    api_groups = ["apps"]
    resources  = ["deployments", "daemonsets"]
    verbs      = ["get", "list", "watch", "create", "update", "patch", "delete"]
  }
  rule {
    api_groups = ["networking.k8s.io"]
    resources  = ["ingresses"]
    verbs      = ["get", "list", "watch", "create", "update", "patch", "delete"]
  }
  # Only the CronJob objects; their Jobs and Pods belong to the CronJob controller.
  rule {
    api_groups = ["batch"]
    resources  = ["cronjobs"]
    verbs      = ["get", "list", "watch", "create", "update", "patch", "delete"]
  }
}

resource "kubernetes_role_binding_v1" "k3s_apps_ci" {
  metadata {
    name = "k3s-apps-ci"
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role_v1.k3s_apps_ci.metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account_v1.k3s_apps_ci.metadata[0].name
    namespace = kubernetes_service_account_v1.k3s_apps_ci.metadata[0].namespace
  }
}

# k3s-apps' node_exporter module only needs its DaemonSet in that namespace.
resource "kubernetes_role_v1" "k3s_apps_ci_node_exporter" {
  metadata {
    name      = "k3s-apps-ci"
    namespace = kubernetes_namespace_v1.node_exporter.metadata[0].name
  }

  rule {
    api_groups = ["apps"]
    resources  = ["daemonsets"]
    verbs      = ["get", "list", "watch", "create", "update", "patch", "delete"]
  }
}

resource "kubernetes_role_binding_v1" "k3s_apps_ci_node_exporter" {
  metadata {
    name      = "k3s-apps-ci"
    namespace = kubernetes_namespace_v1.node_exporter.metadata[0].name
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role_v1.k3s_apps_ci_node_exporter.metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account_v1.k3s_apps_ci.metadata[0].name
    namespace = kubernetes_service_account_v1.k3s_apps_ci.metadata[0].namespace
  }
}

# What k3s-apps' grafana, alertmanager and kube-state-metrics need in monitoring.
resource "kubernetes_role_v1" "k3s_apps_ci_monitoring" {
  metadata {
    name      = "k3s-apps-ci"
    namespace = kubernetes_namespace_v1.monitoring.metadata[0].name
  }

  rule {
    api_groups = [""]
    resources  = ["services", "configmaps", "secrets"]
    verbs      = ["get", "list", "watch", "create", "update", "patch", "delete"]
  }
  rule {
    api_groups = ["apps"]
    resources  = ["deployments"]
    verbs      = ["get", "list", "watch", "create", "update", "patch", "delete"]
  }
}

resource "kubernetes_role_binding_v1" "k3s_apps_ci_monitoring" {
  metadata {
    name      = "k3s-apps-ci"
    namespace = kubernetes_namespace_v1.monitoring.metadata[0].name
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role_v1.k3s_apps_ci_monitoring.metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account_v1.k3s_apps_ci.metadata[0].name
    namespace = kubernetes_service_account_v1.k3s_apps_ci.metadata[0].namespace
  }
}

# What k3s-apps' authelia module creates in auth.
resource "kubernetes_role_v1" "k3s_apps_ci_auth" {
  metadata {
    name      = "k3s-apps-ci"
    namespace = kubernetes_namespace_v1.auth.metadata[0].name
  }

  rule {
    api_groups = [""]
    resources  = ["services", "secrets", "persistentvolumeclaims"]
    verbs      = ["get", "list", "watch", "create", "update", "patch", "delete"]
  }
  rule {
    api_groups = ["apps"]
    resources  = ["deployments"]
    verbs      = ["get", "list", "watch", "create", "update", "patch", "delete"]
  }
  rule {
    api_groups = ["batch"]
    resources  = ["cronjobs"]
    verbs      = ["get", "list", "watch", "create", "update", "patch", "delete"]
  }
}

resource "kubernetes_role_binding_v1" "k3s_apps_ci_auth" {
  metadata {
    name      = "k3s-apps-ci"
    namespace = kubernetes_namespace_v1.auth.metadata[0].name
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role_v1.k3s_apps_ci_auth.metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account_v1.k3s_apps_ci.metadata[0].name
    namespace = kubernetes_service_account_v1.k3s_apps_ci.metadata[0].namespace
  }
}

# The apps' Role, the same kinds as the default one it replaces.
resource "kubernetes_role_v1" "k3s_apps_ci_apps" {
  metadata {
    name      = "k3s-apps-ci"
    namespace = kubernetes_namespace_v1.apps.metadata[0].name
  }

  rule {
    api_groups = [""]
    resources  = ["services", "configmaps", "secrets", "persistentvolumeclaims", "endpoints"]
    verbs      = ["get", "list", "watch", "create", "update", "patch", "delete"]
  }
  rule {
    api_groups = ["apps"]
    resources  = ["deployments"]
    verbs      = ["get", "list", "watch", "create", "update", "patch", "delete"]
  }
  rule {
    api_groups = ["networking.k8s.io"]
    resources  = ["ingresses"]
    verbs      = ["get", "list", "watch", "create", "update", "patch", "delete"]
  }
  # Only the CronJob objects; their Jobs and Pods belong to the CronJob controller.
  rule {
    api_groups = ["batch"]
    resources  = ["cronjobs"]
    verbs      = ["get", "list", "watch", "create", "update", "patch", "delete"]
  }
}

resource "kubernetes_role_binding_v1" "k3s_apps_ci_apps" {
  metadata {
    name      = "k3s-apps-ci"
    namespace = kubernetes_namespace_v1.apps.metadata[0].name
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role_v1.k3s_apps_ci_apps.metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account_v1.k3s_apps_ci.metadata[0].name
    namespace = kubernetes_service_account_v1.k3s_apps_ci.metadata[0].namespace
  }
}
