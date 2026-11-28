# Bootstrap root: the runner, cluster-scoped PVs and privilege-defining RBAC. See README.

# Namespaces and their PSA labels moved to platform/namespaces/, synced by the platform Argo CD (ADR 0037, stage 1).
removed {
  from = kubernetes_namespace_v1.ci
  lifecycle {
    destroy = false
  }
}

removed {
  from = kubernetes_namespace_v1.node_exporter
  lifecycle {
    destroy = false
  }
}

removed {
  from = kubernetes_namespace_v1.monitoring
  lifecycle {
    destroy = false
  }
}

removed {
  from = kubernetes_namespace_v1.auth
  lifecycle {
    destroy = false
  }
}

removed {
  from = kubernetes_namespace_v1.arc_system
  lifecycle {
    destroy = false
  }
}

removed {
  from = kubernetes_namespace_v1.apps
  lifecycle {
    destroy = false
  }
}

removed {
  from = kubernetes_namespace_v1.argocd
  lifecycle {
    destroy = false
  }
}

removed {
  from = kubernetes_labels.default_namespace_psa
  lifecycle {
    destroy = false
  }
}

module "github_runner" {
  source = "./modules/github_runner"

  namespace                = "ci"
  arc_controller_namespace = "arc-system"

  github_runner_app_id              = local.home_infra_github_runner["app_id"]
  github_runner_app_private_key     = local.home_infra_github_runner["app_private_key"]
  github_runner_app_installation_id = var.github_runner_app_installation_id
  github_runner_repositories        = var.github_runner_repositories

  github_runner_stalwart_api_repositories = ["stalwart-config"]
}
