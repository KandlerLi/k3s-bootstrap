# The runner's GitHub App credentials, read from Secrets Manager at plan time.

data "aws_secretsmanager_secret_version" "home_infra_github_runner" {
  secret_id = "home-infra/github-runner"
}

locals {
  home_infra_github_runner = jsondecode(data.aws_secretsmanager_secret_version.home_infra_github_runner.secret_string)
}
