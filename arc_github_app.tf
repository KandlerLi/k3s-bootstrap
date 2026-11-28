# The GitHub App credential ARC's controller and listeners register runners with; it stays in this local root, out of
# every in-cluster role (ADR 0037). ARC itself is in platform/apps/arc/. See README, "Runner design".
resource "kubernetes_secret_v1" "arc_github_app" {
  metadata {
    name      = "arc-github-app"
    namespace = "ci"
  }

  data = {
    github_app_id              = local.home_infra_github_runner["app_id"]
    github_app_installation_id = var.github_runner_app_installation_id
    github_app_private_key     = local.home_infra_github_runner["app_private_key"]
  }

  type = "Opaque"
}

moved {
  from = module.github_runner.kubernetes_secret_v1.arc_github_app
  to   = kubernetes_secret_v1.arc_github_app
}

# Moved to platform/apps/arc/ and platform/ci/, synced by the platform Argo CD (ADR 0037, stage 4).
removed {
  from = module.github_runner.helm_release.arc_controller
  lifecycle {
    destroy = false
  }
}

removed {
  from = module.github_runner.helm_release.arc_scale_set
  lifecycle {
    destroy = false
  }
}

removed {
  from = module.github_runner.kubernetes_network_policy_v1.github_runner_isolation
  lifecycle {
    destroy = false
  }
}

removed {
  from = module.github_runner.kubernetes_network_policy_v1.github_runner_stalwart_api
  lifecycle {
    destroy = false
  }
}
