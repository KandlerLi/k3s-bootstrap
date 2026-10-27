# One Deployment per repository and slot, pinned to k3s-node-2: see README, "Runner design".

locals {
  # Its own Deployment per slot: two dockerd processes must never share one docker-data root.
  github_runner_slots_by_key = {
    for pair in setproduct(var.github_runner_repositories, range(1, var.github_runner_slots_per_repository + 1)) :
    "${pair[0].id}-${pair[1]}" => merge(pair[0], {
      slot                 = pair[1]
      service_account_name = try(var.github_runner_service_accounts[pair[0].id], null)
    })
  }

  runner_image = "myoung34/github-runner:2.337.0-debian-trixie@sha256:ab5c1f5abd6e96fa357c5003575a6b431265d5e7a41d81b5ec690abf3163dad7"
}

# default-network-opts sets the MTU for every bridge network, custom ones included: see README, "Runner design".
resource "kubernetes_config_map_v1" "github_runner_dind_daemon_config" {
  metadata {
    name      = "github-runner-dind-daemon-config"
    namespace = var.namespace
  }

  data = {
    "daemon.json" = jsonencode({
      mtu = 1450
      default-network-opts = {
        bridge = {
          "com.docker.network.driver.mtu" = "1450"
        }
      }
    })
  }
}

resource "kubernetes_deployment_v1" "github_runner" {
  for_each = local.github_runner_slots_by_key

  metadata {
    name      = "github-runner-${each.key}"
    namespace = var.namespace
  }

  spec {
    replicas = 1

    selector {
      match_labels = {
        app = "github-runner-${each.key}"
      }
    }

    template {
      metadata {
        labels = {
          app = "github-runner-${each.key}"
        }

        # Rolls every runner Pod when the App key rotates; env from a Secret is only read at start.
        annotations = {
          "checksum/token" = sha256(kubernetes_secret_v1.github_runner_token.data["app_private_key"])
        }
      }

      spec {
        # Only k3s-apps' runners get a ServiceAccount token: see README, "Runner design".
        automount_service_account_token = each.value.service_account_name != null
        service_account_name            = each.value.service_account_name

        node_selector = {
          "kubernetes.io/hostname" = "k3s-node-2"
        }

        toleration {
          key      = "ci"
          operator = "Equal"
          value    = "github-runner"
          effect   = "NoSchedule"
        }

        # Seeds the shared install volume once per image, not per Pod: see README, "Runner design".
        init_container {
          name  = "seed-runner-install"
          image = local.runner_image
          command = ["sh", "-c", <<-EOT
            set -e
            cd /actions-runner-shared
            if [ "$(cat .seeded-image 2>/dev/null)" != "$RUNNER_IMAGE" ]; then
              find . -mindepth 1 -delete
              cp -a /actions-runner/. .
              echo "$RUNNER_IMAGE" > .seeded-image
            fi
            find _diag -type f -mtime +7 -delete 2>/dev/null || true
          EOT
          ]

          env {
            name  = "RUNNER_IMAGE"
            value = local.runner_image
          }

          volume_mount {
            name       = "actions-runner-install"
            mount_path = "/actions-runner-shared"
          }
        }

        container {
          name  = "runner"
          image = local.runner_image

          # Fresh /work per job, umask 000 for the uid mismatch, registers only once dind answers: see README, "Runner design".
          command = ["sh", "-c", <<-EOT
            find /work -mindepth 1 -delete
            umask 000
            i=0
            until docker info >/dev/null 2>&1; do
              i=$((i + 1))
              [ $((i % 30)) -ne 0 ] || echo "still waiting for dind after $${i}s" >&2
              sleep 1
            done
            exec /entrypoint.sh "$@"
          EOT
          , "sh"]
          args = ["./bin/Runner.Listener", "run", "--startuptype", "service"]

          # GitHub App auth: the entrypoint mints a short-lived installation token at start.
          env {
            name = "APP_ID"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.github_runner_token.metadata[0].name
                key  = "app_id"
              }
            }
          }
          env {
            name = "APP_PRIVATE_KEY"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.github_runner_token.metadata[0].name
                key  = "app_private_key"
              }
            }
          }
          env {
            name  = "APP_LOGIN"
            value = var.github_runner_owner
          }
          env {
            name  = "REPO_URL"
            value = "https://github.com/${var.github_runner_owner}/${each.value.repository}"
          }
          env {
            name  = "RUNNER_SCOPE"
            value = "repo"
          }
          # The prefix tells these runners apart in GitHub's runner list.
          env {
            name  = "RUNNER_NAME"
            value = "k3s-node-2-${each.key}"
          }
          # Unchanged labels keep every repository's runs-on selector working.
          env {
            name  = "LABELS"
            value = "home,debian,x64"
          }
          # The entrypoint treats any set value as true; set explicitly so ephemeral mode is deliberate.
          env {
            name  = "EPHEMERAL"
            value = "true"
          }
          # Update by bumping the image, never inside a running container.
          env {
            name  = "DISABLE_AUTO_UPDATE"
            value = "true"
          }
          # The dind sidecar owns dockerd.
          env {
            name  = "START_DOCKER_SERVICE"
            value = "false"
          }
          # The listener stays uid 0, one less identity mismatch.
          env {
            name  = "RUN_AS_ROOT"
            value = "true"
          }
          # The shared Unix socket, not TCP: see README, "Runner design".
          env {
            name  = "DOCKER_HOST"
            value = "unix:///var/run/docker.sock"
          }
          # The same path in both containers: container: jobs bind-mount from dockerd's filesystem.
          env {
            name  = "RUNNER_WORKDIR"
            value = "/work"
          }

          # Writable root filesystem: this is the CI job's working directory. Limits: see README, "Runner design".
          resources {
            requests = {
              cpu    = "10m"
              memory = "128Mi"
            }
            limits = {
              cpu    = "2000m"
              memory = "1Gi"
            }
          }

          volume_mount {
            name       = "actions-runner-install"
            mount_path = "/actions-runner"
          }
          volume_mount {
            name       = "work"
            mount_path = "/work"
          }
          volume_mount {
            name       = "docker-socket"
            mount_path = "/var/run"
          }
          # Same absolute path in both containers: see README, "Runner design".
          volume_mount {
            name       = "terraform-plugin-cache"
            mount_path = "/terraform-plugin-cache"
          }
        }

        container {
          name  = "dind"
          image = "docker:29.7.2-dind@sha256:12e683a161823b2a839aeea999b9d960e6e1f9a97b1679ad6b441982e2d9cf07"

          # Unix socket only, and dockerd retried in place instead of via CrashLoopBackOff: see README, "Runner design".
          command = ["sh", "-c", <<-EOT
            trap 'kill -TERM "$child" 2>/dev/null; wait "$child"; exit 0' TERM INT
            while true; do
              dockerd-entrypoint.sh dockerd --host=unix:///var/run/docker.sock &
              child=$!
              wait "$child"
              echo "dockerd exited with $?, retrying in 5s" >&2
              sleep 5
            done
          EOT
          ]

          env {
            name  = "DOCKER_TLS_CERTDIR"
            value = ""
          }

          security_context {
            privileged = true
          }

          resources {
            requests = {
              cpu    = "50m"
              memory = "128Mi"
            }
            limits = {
              cpu    = "1000m"
              memory = "768Mi"
            }
          }

          volume_mount {
            name       = "docker-data"
            mount_path = "/var/lib/docker"
          }
          # Same paths as the runner container, so container: job bind mounts resolve.
          volume_mount {
            name       = "actions-runner-install"
            mount_path = "/actions-runner"
          }
          volume_mount {
            name       = "work"
            mount_path = "/work"
          }
          # dockerd creates its socket here, shared with the runner container.
          volume_mount {
            name       = "docker-socket"
            mount_path = "/var/run"
          }
          # The MTU fix, see the ConfigMap above.
          volume_mount {
            name       = "dind-daemon-config"
            mount_path = "/etc/docker/daemon.json"
            sub_path   = "daemon.json"
            read_only  = true
          }
          # Same path as in the runner container: bind-mount sources resolve on dockerd's side.
          volume_mount {
            name       = "terraform-plugin-cache"
            mount_path = "/terraform-plugin-cache"
          }
        }

        # Prunes unused images and build cache so the docker-data hostPath stays bounded.
        container {
          name  = "pruner"
          image = "docker:29.7.2-dind@sha256:12e683a161823b2a839aeea999b9d960e6e1f9a97b1679ad6b441982e2d9cf07"

          command = ["sh", "-c"]
          args = [
            <<-EOT
              while true; do
                sleep ${var.github_runner_prune_interval_seconds}
                docker image prune --all --force --filter until=${var.github_runner_prune_unused_image_age} || true
                docker builder prune --force --keep-storage ${var.github_runner_prune_build_cache_keep_storage} || true
              done
            EOT
          ]

          env {
            name  = "DOCKER_HOST"
            value = "unix:///var/run/docker.sock"
          }

          resources {
            requests = {
              cpu    = "5m"
              memory = "16Mi"
            }
            limits = {
              cpu    = "100m"
              memory = "128Mi"
            }
          }

          volume_mount {
            name       = "docker-socket"
            mount_path = "/var/run"
          }
        }

        # host_path, not emptyDir: the caches survive ephemeral Pods. Scoped per slot: see README, "Runner design".
        volume {
          name = "docker-data"
          host_path {
            path = "/var/lib/k3s-github-runner-cache/${each.key}/docker-data"
            type = "DirectoryOrCreate"
          }
        }
        volume {
          name = "terraform-plugin-cache"
          host_path {
            path = "/var/lib/k3s-github-runner-cache/${each.key}/terraform-plugin-cache"
            type = "DirectoryOrCreate"
          }
        }
        volume {
          name = "actions-runner-install"
          host_path {
            path = "/var/lib/k3s-github-runner-cache/${each.key}/actions-runner"
            type = "DirectoryOrCreate"
          }
        }
        volume {
          name = "work"
          empty_dir {}
        }
        volume {
          name = "docker-socket"
          empty_dir {}
        }
        volume {
          name = "dind-daemon-config"
          config_map {
            name = kubernetes_config_map_v1.github_runner_dind_daemon_config.metadata[0].name
          }
        }
      }
    }
  }
}
