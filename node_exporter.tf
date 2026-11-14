# node-exporter: one privileged Pod per node, the runner node included, for the homeserver's Prometheus. See README, "Namespaces".

# Moved from k3s-apps' modules/node_exporter (removed there with destroy = false).
import {
  to = kubernetes_daemon_set_v1.node_exporter
  id = "node-exporter/node-exporter"
}

resource "kubernetes_daemon_set_v1" "node_exporter" {
  metadata {
    name      = "node-exporter"
    namespace = kubernetes_namespace_v1.node_exporter.metadata[0].name
  }

  spec {
    selector {
      match_labels = {
        app = "node-exporter"
      }
    }

    template {
      metadata {
        labels = {
          app = "node-exporter"
        }
      }

      spec {
        automount_service_account_token = false

        toleration {
          key      = "ci"
          operator = "Equal"
          value    = "github-runner"
          effect   = "NoSchedule"
        }

        # host_network: it reports the node's real stats, and Prometheus outside the cluster reaches it directly.
        host_network = true
        host_pid     = true
        dns_policy   = "ClusterFirstWithHostNet"

        security_context {
          seccomp_profile {
            type = "RuntimeDefault"
          }
        }

        container {
          name = "node-exporter"
          # Same image as home-infra's node_exporter, so metric names never diverge.
          image = "prom/node-exporter:v1.12.1@sha256:1b4e4438faca4dd7e001dd445d161a4a2091b0fededa84093b3a8dfeae1f1be0"

          args = [
            "--path.procfs=/host/proc",
            "--path.sysfs=/host/sys",
            "--path.rootfs=/host/root",
            "--collector.filesystem.mount-points-exclude=^/(dev|proc|sys|host/root/(dev|proc|sys)($|/)).*",
          ]

          port {
            name           = "metrics"
            container_port = 9100
            host_port      = 9100
          }

          resources {
            requests = {
              cpu    = "10m"
              memory = "32Mi"
            }
            limits = {
              cpu    = "100m"
              memory = "64Mi"
            }
          }

          # Runs as nobody, which can read everything it needs.
          security_context {
            allow_privilege_escalation = false
            read_only_root_filesystem  = true
            run_as_non_root            = true
            run_as_user                = 65534
            run_as_group               = 65534
            capabilities {
              drop = ["ALL"]
            }
          }

          volume_mount {
            name       = "proc"
            mount_path = "/host/proc"
            read_only  = true
          }
          volume_mount {
            name       = "sys"
            mount_path = "/host/sys"
            read_only  = true
          }
          volume_mount {
            name       = "root"
            mount_path = "/host/root"
            read_only  = true
          }
        }

        volume {
          name = "proc"
          host_path {
            path = "/proc"
          }
        }
        volume {
          name = "sys"
          host_path {
            path = "/sys"
          }
        }
        volume {
          name = "root"
          host_path {
            path = "/"
          }
        }
      }
    }
  }
}
