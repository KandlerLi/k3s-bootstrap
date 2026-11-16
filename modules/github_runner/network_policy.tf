# Keeps CI code away from the rest of the cluster and private networks: see README, "Runner design".

resource "kubernetes_network_policy_v1" "github_runner_isolation" {
  metadata {
    name      = "github-runner-isolation"
    namespace = var.namespace
  }

  spec {
    pod_selector {
      match_labels = { "github-runner" = "true" }
    }

    policy_types = ["Ingress", "Egress"]

    egress {
      to {
        namespace_selector {
          match_labels = { "kubernetes.io/metadata.name" = "kube-system" }
        }
        pod_selector {
          match_labels = { "k8s-app" = "kube-dns" }
        }
      }
      ports {
        protocol = "UDP"
        port     = "53"
      }
      ports {
        protocol = "TCP"
        port     = "53"
      }
    }

    egress {
      to {
        ip_block {
          cidr   = "0.0.0.0/0"
          except = ["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "100.64.0.0/10", "169.254.0.0/16"]
        }
      }
    }
  }
}

# stalwart-config applies Stalwart's settings through its API: that one port, no Kubernetes API.
resource "kubernetes_network_policy_v1" "github_runner_stalwart_api" {
  metadata {
    name      = "github-runner-stalwart-api"
    namespace = var.namespace
  }

  spec {
    pod_selector {
      match_labels = { "github-runner-stalwart-api" = "true" }
    }

    policy_types = ["Egress"]

    egress {
      to {
        namespace_selector {
          match_labels = { "kubernetes.io/metadata.name" = "apps" }
        }
        pod_selector {
          match_labels = { app = "stalwart" }
        }
      }
      ports {
        protocol = "TCP"
        port     = "8080"
      }
    }
  }
}

# Runner Pods may reach the registry cache's port, and nothing else in the cluster.
resource "kubernetes_network_policy_v1" "github_runner_registry_cache" {
  metadata {
    name      = "github-runner-registry-cache"
    namespace = var.namespace
  }

  spec {
    pod_selector {
      match_labels = { "github-runner" = "true" }
    }

    policy_types = ["Egress"]

    egress {
      to {
        pod_selector {
          match_labels = { app = "registry-cache" }
        }
      }
      ports {
        protocol = "TCP"
        port     = tostring(local.registry_cache_port)
      }
    }
  }
}

# The cache itself: pulled from by runner Pods only, fetches from the public internet only.
resource "kubernetes_network_policy_v1" "registry_cache" {
  metadata {
    name      = "registry-cache"
    namespace = var.namespace
  }

  spec {
    pod_selector {
      match_labels = { app = "registry-cache" }
    }

    policy_types = ["Ingress", "Egress"]

    ingress {
      from {
        pod_selector {
          match_labels = { "github-runner" = "true" }
        }
      }
      ports {
        protocol = "TCP"
        port     = tostring(local.registry_cache_port)
      }
    }

    egress {
      to {
        namespace_selector {
          match_labels = { "kubernetes.io/metadata.name" = "kube-system" }
        }
        pod_selector {
          match_labels = { "k8s-app" = "kube-dns" }
        }
      }
      ports {
        protocol = "UDP"
        port     = "53"
      }
      ports {
        protocol = "TCP"
        port     = "53"
      }
    }

    egress {
      to {
        ip_block {
          cidr   = "0.0.0.0/0"
          except = ["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "100.64.0.0/10", "169.254.0.0/16"]
        }
      }
      ports {
        protocol = "TCP"
        port     = "443"
      }
    }
  }
}
