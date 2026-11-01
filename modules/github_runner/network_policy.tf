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

resource "kubernetes_network_policy_v1" "github_runner_cluster_access" {
  metadata {
    name      = "github-runner-cluster-access"
    namespace = var.namespace
  }

  spec {
    pod_selector {
      match_labels = { "github-runner-cluster-access" = "true" }
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

    # k3s-apps' Blocky password rotation: ALTER USER on Postgres, then health checks on Blocky and Grafana.
    egress {
      to {
        namespace_selector {
          match_labels = { "kubernetes.io/metadata.name" = "apps" }
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
          match_labels = { "kubernetes.io/metadata.name" = "monitoring" }
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

moved {
  from = kubernetes_network_policy_v1.github_runner_cluster_access[0]
  to   = kubernetes_network_policy_v1.github_runner_cluster_access
}
