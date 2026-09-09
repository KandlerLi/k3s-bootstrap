# Reads the real GitHub PAT this root's own github_runner module needs
# directly from AWS Secrets Manager -- the SOPS-to-Secrets-Manager
# cutover (PARKED.md's own writeup). Replaces the TF_VAR_github_runner_
# github_token a human used to supply at apply time (originally sourced
# from infra/home-infra's own SOPS vault). Mirrors infra/k3s-apps' own
# secrets.tf -- see that file's comment for the fuller pattern
# rationale (one data source per Secrets Manager group, jsondecode()'d
# once into a local).

data "aws_secretsmanager_secret_version" "home_infra_github_runner" {
  secret_id = "home-infra/github-runner"
}

locals {
  home_infra_github_runner = jsondecode(data.aws_secretsmanager_secret_version.home_infra_github_runner.secret_string)
}
