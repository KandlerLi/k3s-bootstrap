# Secret values, read from Secrets Manager at plan time.

data "aws_secretsmanager_secret_version" "home_infra_github_runner" {
  secret_id = "home-infra/github-runner"
}

# Argo CD's Authelia OIDC client secret (plaintext half).
data "aws_secretsmanager_secret_version" "home_infra_argocd" {
  secret_id = "home-infra/argocd"
}

locals {
  home_infra_argocd        = jsondecode(data.aws_secretsmanager_secret_version.home_infra_argocd.secret_string)
  home_infra_github_runner = jsondecode(data.aws_secretsmanager_secret_version.home_infra_github_runner.secret_string)
}
