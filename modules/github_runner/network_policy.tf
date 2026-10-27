# Keeps CI code away from the rest of the cluster and private networks: see README, "Runner design".

locals {
  runner_app_labels = [for key in keys(local.github_runner_slots_by_key) : "github-runner-${key}"]
  cluster_access_runner_app_labels = [
    for key, slot in local.github_runner_slots_by_key : "github-runner-${key}"
    if slot.service_account_name != null
  ]
}

resource "kubernetes_network_policy_v1" "github_runner_isolation" {
  metadata {
    name      = "github-runner-isolation"
    namespace = var.namespace
  }

  spec {
    pod_selector {
      match_expressions {
        key      = "app"
        operator = "In"
        values   = local.runner_app_labels
      }
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

resource "kubernetes_network_policy_v1" "github_runner_cluster_access" {
  count = length(local.cluster_access_runner_app_labels) > 0 ? 1 : 0

  metadata {
    name      = "github-runner-cluster-access"
    namespace = var.namespace
  }

  spec {
    pod_selector {
      match_expressions {
        key      = "app"
        operator = "In"
        values   = local.cluster_access_runner_app_labels
      }
    }

    policy_types = ["Egress"]

    # The API server after kube-proxy's DNAT, plus the ClusterIP if evaluated before translation.
    egress {
      to {
        ip_block {
          cidr = "${var.github_runner_api_server_ip}/32"
        }
      }
      ports {
        protocol = "TCP"
        port     = "6443"
      }
    }
    egress {
      to {
        ip_block {
          cidr = "10.43.0.1/32"
        }
      }
      ports {
        protocol = "TCP"
        port     = "443"
      }
    }

    egress {
      to {
        namespace_selector {
          match_labels = { "kubernetes.io/metadata.name" = "default" }
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

    # k3s-apps' Blocky password rotation: ALTER USER on Postgres, then health checks on Blocky and Grafana.
    egress {
      to {
        namespace_selector {
          match_labels = { "kubernetes.io/metadata.name" = "default" }
        }
        pod_selector {
          match_labels = { app = "blocky" }
        }
      }
      ports {
        protocol = "TCP"
        port     = "5432"
      }
      ports {
        protocol = "TCP"
        port     = "4000"
      }
    }
    egress {
      to {
        namespace_selector {
          match_labels = { "kubernetes.io/metadata.name" = "default" }
        }
        pod_selector {
          match_labels = { app = "grafana" }
        }
      }
      ports {
        protocol = "TCP"
        port     = "3000"
      }
    }
  }
}
