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
