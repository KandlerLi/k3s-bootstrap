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

# Grafana, Alertmanager, kube-state-metrics and Alloy: see README, "Namespaces".
resource "kubernetes_namespace_v1" "monitoring" {
  metadata {
    name = "monitoring"
    labels = {
      "pod-security.kubernetes.io/enforce" = "restricted"
    }
  }
}

# Authelia: see README, "Namespaces".
resource "kubernetes_namespace_v1" "auth" {
  metadata {
    name = "auth"
    labels = {
      "pod-security.kubernetes.io/enforce" = "restricted"
    }
  }
}

# The ARC controller and its listeners: see README, "Namespaces".
resource "kubernetes_namespace_v1" "arc_system" {
  metadata {
    name = "arc-system"
    labels = {
      "pod-security.kubernetes.io/enforce" = "restricted"
    }
  }
}

# Every remaining k3s-apps workload, Traefik included: see README, "Namespaces".
resource "kubernetes_namespace_v1" "apps" {
  metadata {
    name = "apps"
    labels = {
      "pod-security.kubernetes.io/enforce" = "restricted"
    }
  }
}

module "github_runner" {
  source = "./modules/github_runner"

  namespace                = kubernetes_namespace_v1.ci.metadata[0].name
  arc_controller_namespace = kubernetes_namespace_v1.arc_system.metadata[0].name

  github_runner_app_id              = local.home_infra_github_runner["app_id"]
  github_runner_app_private_key     = local.home_infra_github_runner["app_private_key"]
  github_runner_app_installation_id = var.github_runner_app_installation_id
  github_runner_repositories        = var.github_runner_repositories

  github_runner_stalwart_api_repositories = ["stalwart-config"]

  registry_cache_ghcr_token = local.k3s_apps_ghcr_pull_token["token"]
}
