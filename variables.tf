variable "github_runner_github_token" {
  description = <<-EOT
    Fine-grained GitHub PAT with Administration: write on every
    repository in var.github_runner_repositories -- same value as
    home-infra's github_runner_github_token SOPS secret. Pass via
    TF_VAR_github_runner_github_token at apply time.
  EOT
  type        = string
  sensitive   = true
}

variable "github_runner_repositories" {
  description = <<-EOT
    Loaded from this root's own repositories.auto.tfvars.json
    (Terraform auto-loads it) -- see modules/github_runner's own
    variable of the same name for where that file comes from. No
    default here: if that file is ever missing, this should fail
    loudly rather than silently apply zero runners.
  EOT
  type = list(object({
    id         = string
    repository = string
  }))
}
