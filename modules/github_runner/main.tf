# One Deployment per repository and slot (see
# github_runner_slots_per_repository) in var.github_runner_repositories,
# via for_each -- a data-driven multiplication of one service, unlike
# every sibling app module's own "one module per service" convention.
#
# Every Deployment is pinned to k3s-node-2 and tolerates its
# ci=github-runner:NoSchedule taint, so CI workloads never compete
# with, or endanger, anything on k3s-node-1.
#
# Docker access: a privileged docker:dind sidecar per Pod, not
# kaniko/rootless building -- a deliberate, accepted trade-off: every
# repository's existing `docker build`/`docker run` workflow steps
# keep working completely unmodified, at the real cost that a
# privileged container can escape to its own node. Contained to
# k3s-node-2 alone, which runs nothing else. Reached over a shared
# Unix socket volume, not TCP -- docker:dind's own entrypoint never
# opens a TCP listener just because DOCKER_TLS_CERTDIR="" is set (that
# only skips TLS cert generation).
#
# Full migration history and every bug found building this (the
# container: job bind-mount failure, the cross-machine uid mismatch,
# the auth migration, the disk-growth/pruner story, the capacity
# tuning): docs/home-infra-ai-context's current-state.md ("k3s
# learning cluster") and decisions.md.
#
# Runner image: the community myoung34/github-runner image, not a
# hand-rolled entrypoint -- its own registration/deregistration logic
# replaces the drift/busy-safety Ansible asserts home-infra's own
# (now-deleted) role needed for a persistent systemd service; a
# Kubernetes Deployment restarting a Pod doesn't have that problem.

locals {
  # One entry per (repository, slot): every slot is its own Deployment
  # (own Pod, own dind, own docker-data hostPath), so a PR job and a
  # main job for the same repository can run at the same time. Not
  # replicas > 1 on one Deployment: that would point two dockerd
  # processes at a single docker-data root.
  github_runner_slots_by_key = {
    for pair in setproduct(var.github_runner_repositories, range(1, var.github_runner_slots_per_repository + 1)) :
    "${pair[0].id}-${pair[1]}" => merge(pair[0], {
      slot                 = pair[1]
      service_account_name = try(var.github_runner_service_accounts[pair[0].id], null)
    })
  }
}

# A path-MTU black hole, not flakiness -- see current-state.md's "k3s
# learning cluster" entry for the full tcpdump-diagnosed story.
# "default-network-opts" is Docker's own documented mechanism for
# setting the default driver options -- including mtu -- for every
# bridge network the daemon creates from then on, custom ones included
# (a plain "mtu" key alone only covers the *default* bridge network,
# not the fresh custom network GitHub's own runner creates per job). A
# daemon.json file, not a --mtu command/args override -- dockerd reads
# this automatically regardless of how it's invoked.
resource "kubernetes_config_map_v1" "github_runner_dind_daemon_config" {
  metadata {
    name = "github-runner-dind-daemon-config"
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
    name = "github-runner-${each.key}"
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

        # The "runner" container's own credentials are
        # env.valueFrom.secretKeyRef, read once at container start and
        # never refreshed -- same class of gap already fixed for
        # infra/k3s-apps' modules/ingress/modules/alertmanager. This
        # checksum makes rotation deterministic: changing the shared
        # Secret's value rolls every one of these Deployments' Pods at
        # once. Hashes the private key specifically, not app_id (which
        # never changes on its own -- rotation means generating a
        # fresh key in the App's own settings, not a new App).
        annotations = {
          "checksum/token" = sha256(kubernetes_secret_v1.github_runner_token.data["app_private_key"])
        }
      }

      spec {
        # Every repo except one gets the old behaviour: neither
        # container talks to the Kubernetes API at all. k3s-apps' own
        # entry gets a real ServiceAccount name via
        # var.github_runner_service_accounts (see variables.tf), which
        # flips this on and mounts that ServiceAccount's token into
        # every container in the Pod -- including the "runner"
        # container itself, so a job step with no container: key (see
        # k3s-apps' own checks.yml/apply.yml) sees it automatically,
        # the same way any in-cluster process would.
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

        # Seeds the shared actions-runner-install volume from this same
        # image's own baked-in /actions-runner before either main
        # container starts -- see the header comment above for why this
        # needs to be real, shared, non-empty content rather than a
        # plain empty_dir mounted straight over the image's own install.
        init_container {
          name    = "seed-runner-install"
          image   = "myoung34/github-runner:2.337.0-debian-trixie@sha256:ab5c1f5abd6e96fa357c5003575a6b431265d5e7a41d81b5ec690abf3163dad7"
          command = ["sh", "-c", "cp -a /actions-runner/. /actions-runner-shared/"]

          volume_mount {
            name       = "actions-runner-install"
            mount_path = "/actions-runner-shared"
          }
        }

        container {
          name  = "runner"
          image = "myoung34/github-runner:2.337.0-debian-trixie@sha256:ab5c1f5abd6e96fa357c5003575a6b431265d5e7a41d81b5ec690abf3163dad7"

          # umask 000 fixes the cross-machine uid mismatch at the
          # actual source -- see current-state.md for the polling
          # chmod fixer this replaced (it actively fought home-infra's
          # own checks.yml security check). Minimal override -- same
          # ENTRYPOINT/CMD as the image's own default, so
          # entrypoint.sh's own setup logic runs unchanged; only the
          # umask ahead of its exec differs.
          command = ["sh", "-c", "umask 000 && exec /entrypoint.sh \"$@\"", "sh"]
          args    = ["./bin/Runner.Listener", "run", "--startuptype", "service"]

          # GitHub App auth, not a static ACCESS_TOKEN -- the
          # entrypoint's own app_token.sh signs a JWT with
          # APP_PRIVATE_KEY and mints a fresh, short-lived installation
          # access token at container start, using APP_ID to identify
          # the App and APP_LOGIN (var.github_runner_owner -- a plain
          # value, not a Secret key, since it's the same public account
          # name REPO_URL below already uses) to resolve which
          # installation to mint it for. See decisions.md's "GHCR image
          # pulls stay on a classic PAT" entry for why this and the
          # GHCR pull token took different paths.
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
          # k3s-node-2-<id>, not <id> alone -- distinct from the old VM's
          # own github-runner-<id> names so both can register and serve
          # side by side during the additive rollout (Phase C), and so
          # it's obvious from GitHub's own runner list which one picked
          # up a given job.
          env {
            name  = "RUNNER_NAME"
            value = "k3s-node-2-${each.key}"
          }
          # Matches today's real labels exactly, so every repository's
          # existing runs-on: [self-hosted, home, debian] selector keeps
          # working unmodified -- this is what makes the rollout
          # additive rather than requiring a workflow-file change per
          # repository.
          env {
            name  = "LABELS"
            value = "home,debian,x64"
          }
          # Ephemeral, deliberately -- one job per Pod, then it exits
          # and the Deployment restarts it fresh for the next. Confirmed
          # live: the entrypoint's own EPHEMERAL check is `[ -n
          # "${EPHEMERAL}" ]`, true for ANY set value including
          # "false" -- there's no way to opt out of ephemeral mode by
          # setting this to a falsy string, only by leaving it unset
          # entirely, so it's set to "true" here to make the real,
          # already-live behavior explicit rather than accidental. A
          # deliberate departure from the old VM-based role's own
          # persistent-systemd-service shape: ephemeral is GitHub's own
          # recommended pattern for container/k8s-hosted runners, and it
          # sidesteps the whole class of cross-job workspace-reuse bug
          # that role needs real Ansible logic to handle (root-owned
          # leftover files from a containerized job step blocking a
          # later job's own checkout) -- every Pod starts clean.
          env {
            name  = "EPHEMERAL"
            value = "true"
          }
          # The image itself should be bumped to update the runner
          # binary, not have it silently self-update inside a running
          # container -- same reasoning as the old role's own
          # --disableupdate config.sh flag.
          env {
            name  = "DISABLE_AUTO_UPDATE"
            value = "true"
          }
          # This image can also start its own embedded dockerd -- never
          # here, the dind sidecar below owns that entirely.
          env {
            name  = "START_DOCKER_SERVICE"
            value = "false"
          }
          # Keeps this container's own Runner.Listener process as uid 0
          # rather than gosu-ing to an internal non-root account -- one
          # less source of identity mismatch for the case where a
          # workflow's own jobs all land on this same Pod (see this
          # file's own header comment for the known, accepted, bounded
          # limitation when they don't).
          env {
            name  = "RUN_AS_ROOT"
            value = "true"
          }
          # The shared socket volume below, not TCP -- see this file's
          # own header comment for why.
          env {
            name  = "DOCKER_HOST"
            value = "unix:///var/run/docker.sock"
          }
          # A plain, explicit path rather than this image's own
          # /_work/<runner-name> default -- both containers mount the
          # shared "work" volume at this exact path (see the header
          # comment on why it has to be identical on both sides).
          env {
            name  = "RUNNER_WORKDIR"
            value = "/work"
          }

          # No read_only_root_filesystem/non-root here (unlike most
          # other modules' containers) -- this container's filesystem is
          # the real CI job's own working directory; checkout, package
          # installs, and arbitrary workflow steps all need to write to
          # it, the same reason home-infra's own per-repo service
          # accounts were never given a restricted shell either.
          #
          # Memory and CPU limits were each raised twice more after
          # this, against real OOMKills and cgroup-throttling events as
          # infra/k3s-apps' own Terraform state and provider set grew
          # -- see current-state.md's "k3s learning cluster" entry for
          # the full tuning history. This for_each's single resource
          # block covers every repo's own runner, so headroom here
          # benefits all of them. CPU requests stay at 10m regardless
          # of the limit -- only the burst ceiling widens, never what
          # scheduling reserves. This container's own limit can never
          # usefully exceed the node's 2 physical cores; under genuine
          # concurrent load from more than one of this for_each's 8
          # runners at once, that shared physical ceiling is the real
          # constraint, not this per-Pod number.
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
          # Terraform's own provider cache -- see the "dind" container's
          # own identical mount below for why this needs to exist at the
          # same absolute path in both containers, and TF_PLUGIN_CACHE_DIR
          # in infra/k3s-apps' own checks.yml/apply.yml (this repo's
          # terraform runs directly on this container, no container: job
          # involved) and gha-common's terraform-checks.yml/
          # terraform-apply.yml (bind-mounted into their own container:
          # jobs instead, which run on a separate nested Docker network
          # this Pod's own env vars never reach).
          volume_mount {
            name       = "terraform-plugin-cache"
            mount_path = "/terraform-plugin-cache"
          }
        }

        container {
          name  = "dind"
          image = "docker:29.7.2-dind@sha256:12e683a161823b2a839aeea999b9d960e6e1f9a97b1679ad6b441982e2d9cf07"

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

          # host_path now, not emptyDir -- see the volume block below for
          # why.
          volume_mount {
            name       = "docker-data"
            mount_path = "/var/lib/docker"
          }
          # Same two paths, same absolute mount points as the runner
          # container above -- this is what actually fixes the
          # container: job bind-mount failure: the daemon (this
          # container) now has the real files at the paths it's asked
          # to bind-mount from.
          volume_mount {
            name       = "actions-runner-install"
            mount_path = "/actions-runner"
          }
          volume_mount {
            name       = "work"
            mount_path = "/work"
          }
          # dockerd creates docker.sock here on startup -- shared with
          # the runner container above so it can reach it at the exact
          # same path, unix sockets aren't network-addressable.
          volume_mount {
            name       = "docker-socket"
            mount_path = "/var/run"
          }
          # See this file's own header comment on
          # kubernetes_config_map_v1.github_runner_dind_daemon_config
          # for why this exists: without it, this daemon's own internal
          # bridge networks default to MTU 1500, silently black-holing
          # any container: job step's own outbound HTTPS response
          # bodies once they cross into this Pod's real MTU-1450
          # network.
          volume_mount {
            name       = "dind-daemon-config"
            mount_path = "/etc/docker/daemon.json"
            sub_path   = "daemon.json"
            read_only  = true
          }
          # Same path as the "runner" container's own mount above -- a
          # container: job's own bind-mount source (gha-common's
          # terraform-checks.yml/terraform-apply.yml `-v` option) resolves
          # against this daemon's own filesystem, not the client's, the
          # same reason actions-runner-install/work are mounted here too.
          volume_mount {
            name       = "terraform-plugin-cache"
            mount_path = "/terraform-plugin-cache"
          }
        }

        # Keeps each slot's docker-data hostPath (below) from growing
        # without bound -- see current-state.md for the real disk-space
        # incident this fixes. Reuses the dind image (it already ships
        # the docker CLI) instead of adding a new pinned image, and
        # talks to the sibling dockerd over the same shared socket the
        # runner container uses. Unprivileged: the socket is all it
        # needs. Prune only ever removes what is unused, so an
        # in-flight job's images and cache are untouched.
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

        # host_path, not emptyDir, for docker-data/terraform-plugin-cache:
        # EPHEMERAL means a fresh Pod (and a fresh emptyDir) per job, so
        # both Docker's own layer cache and Terraform's own provider
        # cache were being wiped on every single run -- see
        # current-state.md for the 5-8 minute `terraform init` this
        # caused on every PR check. node_selector above already
        # pins every repo's Deployment to k3s-node-2 permanently, so a
        # host_path here persists across Pod restarts exactly the way an
        # actual cache needs to, at no new node-coupling cost. Both scoped
        # under each.key (repository id + slot): every Deployment
        # lands on this same node, and two slots of one repo can run at
        # once (Terraform's plugin cache isn't safe for concurrent writers), so an unscoped shared path would mean
        # independent dockerd processes fighting over one on-disk docker
        # root, or unrelated repos' own Terraform providers colliding in
        # one plugin-cache directory. DirectoryOrCreate so the very first
        # run per repo doesn't need either path pre-created by hand --
        # same pattern infra/k3s-apps' own modules/sankey_export/main.tf
        # already uses for its own single-node hostPath cache.
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
          empty_dir {}
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
