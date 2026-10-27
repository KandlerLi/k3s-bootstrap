# k3s creates default itself, so Terraform only manages its PSA labels: see README, "Namespaces".
resource "kubernetes_labels" "default_namespace_psa" {
  api_version = "v1"
  kind        = "Namespace"

  metadata {
    name = "default"
  }

  labels = {
    "pod-security.kubernetes.io/enforce" = "baseline"
  }
}
