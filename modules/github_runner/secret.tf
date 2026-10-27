# One Secret for every runner: the same GitHub App credentials, rotated in one place.
resource "kubernetes_secret_v1" "github_runner_token" {
  metadata {
    name      = "github-runner-token"
    namespace = var.namespace
  }

  data = {
    app_id          = var.github_runner_app_id
    app_private_key = var.github_runner_app_private_key
  }

  type = "Opaque"
}
