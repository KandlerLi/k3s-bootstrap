# One Secret shared by every repository's Deployment below -- it's the
# same single PAT either way, not a per-repo credential.
resource "kubernetes_secret_v1" "github_runner_token" {
  metadata {
    name = "github-runner-token"
  }

  data = {
    token = var.github_runner_github_token
  }

  type = "Opaque"
}
