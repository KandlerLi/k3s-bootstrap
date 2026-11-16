# Pull-through cache for ghcr.io, so runner Pods pull CI images over the cluster network: see README, "Registry cache".

locals {
  registry_cache_image = "registry:3.1.1@sha256:325b4b29b041e82803abeb703e201655e4e23ab83264ec1a7c9ddb0a5b14a6e0"
  registry_cache_port  = 5000
  registry_cache_uid   = 65534
  # What runner Pods and dind address it as; gha-common reads it from the runner's GHCR_CACHE.
  registry_cache_host = "registry-cache.${var.namespace}.svc.cluster.local:${local.registry_cache_port}"
}

resource "kubernetes_secret_v1" "registry_cache_ghcr" {
  metadata {
    name      = "registry-cache-ghcr"
    namespace = var.namespace
  }

  data = {
    REGISTRY_PROXY_USERNAME = var.github_runner_owner
    REGISTRY_PROXY_PASSWORD = var.registry_cache_ghcr_token
  }

  type = "Opaque"
}

resource "kubernetes_deployment_v1" "registry_cache" {
  metadata {
    name      = "registry-cache"
    namespace = var.namespace
    labels    = { app = "registry-cache" }
  }

  spec {
    replicas = 1

    # One writer on the hostPath.
    strategy {
      type = "Recreate"
    }

    selector {
      match_labels = { app = "registry-cache" }
    }

    template {
      metadata {
        labels = { app = "registry-cache" }
      }

      spec {
        automount_service_account_token = false
        node_selector                   = local.node_2_placement.nodeSelector

        toleration {
          key      = "ci"
          operator = "Equal"
          value    = "github-runner"
          effect   = "NoSchedule"
        }

        security_context {
          seccomp_profile {
            type = "RuntimeDefault"
          }
        }

        # hostPath directories are created root-owned.
        init_container {
          name    = "chown-storage"
          image   = local.registry_cache_image
          command = ["chown", "${local.registry_cache_uid}:${local.registry_cache_uid}", "/var/lib/registry"]

          security_context {
            run_as_user                = 0
            allow_privilege_escalation = false
            read_only_root_filesystem  = true
            capabilities {
              drop = ["ALL"]
              add  = ["CHOWN"]
            }
          }

          volume_mount {
            name       = "storage"
            mount_path = "/var/lib/registry"
          }
        }

        container {
          name  = "registry"
          image = local.registry_cache_image

          # The image's default is debug, with a trace span per request.
          env {
            name  = "REGISTRY_LOG_LEVEL"
            value = "info"
          }
          env {
            name  = "REGISTRY_PROXY_REMOTEURL"
            value = "https://ghcr.io"
          }
          # Cached blobs are dropped this long after their last pull.
          env {
            name  = "REGISTRY_PROXY_TTL"
            value = "168h"
          }

          env_from {
            secret_ref {
              name = kubernetes_secret_v1.registry_cache_ghcr.metadata[0].name
            }
          }

          port {
            container_port = local.registry_cache_port
          }

          readiness_probe {
            http_get {
              path = "/"
              port = local.registry_cache_port
            }
            period_seconds = 10
          }

          security_context {
            run_as_user                = local.registry_cache_uid
            run_as_group               = local.registry_cache_uid
            run_as_non_root            = true
            allow_privilege_escalation = false
            read_only_root_filesystem  = true
            capabilities {
              drop = ["ALL"]
            }
          }

          resources {
            requests = { cpu = "20m", memory = "64Mi" }
            limits   = { memory = "256Mi" }
          }

          volume_mount {
            name       = "storage"
            mount_path = "/var/lib/registry"
          }
        }

        volume {
          name = "storage"
          host_path {
            path = "/var/lib/registry-cache"
            type = "DirectoryOrCreate"
          }
        }
      }
    }
  }
}

resource "kubernetes_service_v1" "registry_cache" {
  metadata {
    name      = "registry-cache"
    namespace = var.namespace
  }

  spec {
    selector = { app = "registry-cache" }

    port {
      port        = local.registry_cache_port
      target_port = local.registry_cache_port
    }
  }
}
