# One Secret shared by every repository's Deployment below -- it's the
# same GitHub App credentials either way, not a per-repo credential.
# app_id isn't itself secret (see its own variable's description), but
# lives here anyway rather than as a plain Deployment env value --
# keeping both App credentials in one place matches how they're
# actually delivered (one JSON blob from AWS Secrets Manager) and
# means a future App-credential rotation only ever touches one
# resource.
resource "kubernetes_secret_v1" "github_runner_token" {
  metadata {
    name = "github-runner-token"
  }

  data = {
    app_id          = var.github_runner_app_id
    app_private_key = var.github_runner_app_private_key
  }

  type = "Opaque"
}
