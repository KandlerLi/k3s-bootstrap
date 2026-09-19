# Phase B of moving github_runner to k3s (see the approved plan in
# home-infra's own plan history): one Deployment per repository and slot (see github_runner_slots_per_repository) in
# var.github_runner_repositories, via for_each -- the first use of
# for_each in this module (originally written alongside 8 sibling
# "one module per distinct service" app modules in infra/k3s-apps,
# before this module and its own root were extracted into this
# standalone repo, 2026-09-03; this is a data-driven multiplication of
# *one* service instead, so it earned the exception rather than
# following that convention).
#
# Also the first use of node_selector/toleration anywhere in infra/
# k3s-apps (or home-infra), at the time -- every Deployment here is
# pinned to k3s-node-2 and
# tolerates its ci=github-runner:NoSchedule taint, the second, tainted
# k3s node ansible/roles/k3s_node now supports specifically so CI
# workloads never compete with, or endanger, anything on k3s-node-1.
#
# Docker access: a privileged docker:dind sidecar per Pod, not
# kaniko/rootless building -- a deliberate, accepted trade-off (see the
# plan): every repository's existing `docker build`/`docker run`
# workflow steps keep working completely unmodified, at the real cost
# that a privileged container can escape to its own node. Contained to
# k3s-node-2 alone, which runs nothing else. Reached over a shared
# Unix socket volume (`/var/run/docker.sock`, an emptyDir mounted at
# the identical path in both containers), not TCP -- confirmed live
# that docker:dind's own entrypoint never actually opens a TCP
# listener just because DOCKER_TLS_CERTDIR="" is set (that only skips
# TLS cert generation); the socket is the only thing it ever binds,
# matching the officially-documented host-socket pattern, just shared
# between two containers in one Pod instead of between a container and
# its host.
#
# Confirmed live and fixed: any job step using GitHub Actions' own
# `container:` job option (every repository's own Validate job, home-
# infra's own checks.yml included) failed with "stat /__e/node24/bin/
# node: no such file or directory" -- actions/runner bind-mounts its
# own /actions-runner/externals (the Node.js runtime for JS-based
# actions) and /_work into the job containers it asks Docker to start,
# and Docker resolves a bind-mount's *source* path against the
# *daemon's* own filesystem, not the client's. With the daemon living
# in a separate dind container, those paths simply didn't exist there.
# Same root cause the image's own upstream docs call out for the
# host-socket case ("this path needs to be the same path on host and
# inside the container") -- just not documented for a separate-sidecar
# dind setup at all. Fixed by sharing both directories as real
# volumes, mounted at the identical absolute path in both containers,
# so the daemon's own filesystem view actually has the files being
# bind-mounted. /actions-runner is baked into the runner image's own
# layer (not empty at start), so a plain empty_dir mounted there would
# shadow the real install -- seeded first by a same-image init
# container instead, the same "seed a volume from image content before
# the real container mounts shift it" shape infra/k3s-apps' own
# modules/deluge's own seed-web-conf init container already
# established.
#
# Confirmed live and fixed: a `container:` job step still got EACCES
# writing into the shared "work" volume even after the bind-mount fix
# above. Root cause is one level deeper than this Pod's own internal
# identity: GitHub Actions' own workflow shape here captures id -u/
# id -g from the "Build CI image" job and passes it as `container:
# options: --user <uid>:<gid>` to the separate "Validate" job -- true
# by construction on the old VM (one shared filesystem, one real
# account), no longer guaranteed once this module's own runners pool
# additively alongside it: confirmed live, a run where "Build CI
# image" executed on the *old* VM (capturing its own real ghr-<id>
# system account's uid) while "Validate" landed on this module's own
# runner, asking to write as a uid that means nothing here.
#
# First fix tried: a dedicated permission-fixer container polling
# `chmod -R 0777 /work`, on the theory that no fix on this Pod's own
# side can predict or match an arbitrary incoming uid, so keep the
# whole tree permissive instead. It worked for the original bug, but
# turned out actively harmful, not just an unnecessary belt-and-
# suspenders: confirmed live, it fought home-infra's own checks.yml,
# which deliberately `chmod o-w`s its own checked-out workspace as a
# real security measure (Ansible refuses to load an ansible.cfg from a
# world-writable directory) -- this loop kept re-adding world-write
# permissions moments later, breaking that repository's own CI outright
# once its runner moved here. Removed. Fixed at the actual source
# instead: the runner container's own `umask 000` (see its comment)
# means anything *this Pod's own process tree* creates is 0777 from
# the instant of creation, with no race to poll for and nothing to
# retroactively widen -- confirmed live, a real checkout succeeded
# cleanly with this alone, no fixer container involved.
#
# Known, accepted, bounded limitation: the fixes above cover a
# `container:` job step *writing* into the shared work volume, but not
# every possible interaction of the cross-machine uid handoff --
# confirmed live, a workflow run where "Build CI image" executed on
# the old VM and "Validate" landed here still occasionally fails a
# later `chmod -R a+rwX "$GITHUB_WORKSPACE"` cleanup step with EPERM,
# even though this Pod's own runner container is root with CAP_FOWNER
# confirmed present (a synthetic touch+chown+chmod reproduction of the
# same shape succeeds cleanly, so the exact mechanism wasn't fully
# root-caused). When both jobs land on the *same* runner instead --
# old+old, or confirmed live, new+new -- every step succeeds, cleanup
# included. This only ever happens during Phase C's additive rollout,
# while both an old-VM and a new-k3s runner share the same labels and
# GitHub can freely mix which one executes which job within one
# workflow run; it disappears entirely and permanently once Phase D
# retires the old VM, leaving only internally-consistent runners. A
# re-run picks a different runner pairing and normally succeeds.
# Accepted deliberately rather than chased further, given the real,
# steep diminishing returns already hit digging into it.
#
# Runner image: the community myoung34/github-runner image, not a
# hand-rolled entrypoint -- its own registration/deregistration logic
# (on container start/stop) replaces the drift/busy-safety Ansible
# asserts in home-infra's configure_repository.yml, which exist
# specifically because that's a *persistent* systemd service Ansible
# reapplies idempotently; a Kubernetes Deployment restarting a Pod
# doesn't have that problem. debian-trixie variant, matching every
# other Debian image pinned elsewhere in this project.
#
# Resources: not yet measured from real usage (first deploy) -- sized
# off the old VM's own proven real-world capacity instead of a guess:
# it already runs all of today's repositories as systemd processes on
# the same 2 vCPU/2048Mi budget k3s-node-2 itself has. Burstable
# (requests small, limits generous) since jobs are occasional/bursty,
# not constantly running -- revisit against real usage once live,
# matching this project's own measure-then-size discipline everywhere
# else there's already real data to size from.

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

# Confirmed live (2026-08-31): a `container:` job's own OIDC credential
# step (aws-actions/configure-aws-credentials) hung for exactly ~90s
# (its own configured action-timeout-s) on its first request, 100%
# reproducible across multiple Pods, then succeeded near-instantly on
# retry -- a path-MTU black hole, not flakiness. Caught it directly via
# a live tcpdump capture during an actual stall: the server sends its
# response fragmented, the client's own kernel SACKs receiving bytes
# 2849:5178 while never receiving bytes 1:2849 at all, and then dead
# silence for the rest of the timeout window -- not one retransmission
# attempt ever arrives. Root cause: the Pod's own eth0 (flannel's VXLAN
# overlay, which correctly accounts for encapsulation overhead) sits at
# MTU 1450, but dind's own *inner* Docker-in-Docker bridge networks --
# where every `container:` job step actually runs -- were still at
# Docker's own untouched default of 1500, with no way to know about the
# outer network's lower ceiling.
#
# A first attempt at this fix used only daemon.json's own "mtu" key --
# confirmed live via the same tcpdump technique that this was
# insufficient: it only changes the *default* bridge network (docker0),
# and GitHub's own runner creates a fresh custom network per job
# (confirmed in dind's own logs: "github_network_<hash>"), which never
# inherits that default at all -- confirmed live via a repeat capture
# that the job container's own SYN still advertised mss 1460 (the
# untouched MTU-1500 value) even after the first fix was live.
# "default-network-opts" is Docker's own documented mechanism for
# exactly this gap: it sets the default driver options -- including
# mtu -- for every bridge network the daemon creates from then on,
# custom ones included, without needing each `docker network create`
# call to pass its own --opt (which isn't ours to control here; the
# runner's own internals issue those calls). A daemon.json file, not a
# --mtu command/args override -- dockerd reads this automatically
# regardless of how it's invoked, so this doesn't need to touch (or
# risk diverging from) the image's own default entrypoint/CMD the way
# overriding command/args would.
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

        # Found live 2026-09-12, ahead of a real PAT rotation (still
        # applies the same way to the App private key that replaced
        # it 2026-09-16): the "runner" container's own credentials are
        # env.valueFrom.secretKeyRef, read once at container start and
        # never refreshed -- same class of gap already fixed for
        # modules/ingress's ACME credentials and modules/alertmanager's
        # config Secret in infra/k3s-apps. Ephemeral mode (EPHEMERAL=
        # true below) bounds the staleness window to "until this Pod's
        # current job finishes," not indefinite, but an idle runner
        # waiting on its next job could sit on a stale credential for a
        # long time regardless. This checksum makes rotation
        # deterministic: changing the shared Secret's value changes
        # every one of these Deployments' pod templates, so Kubernetes
        # rolls a fresh Pod on its own -- what "one apply rolls every
        # runner at once" (this module's own README) actually requires
        # to be true. Hashes the private key specifically, not app_id
        # (which never changes on its own -- rotation here means
        # generating a fresh key in the App's own settings, not a new
        # App).
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

          # An earlier fix here was a separate container polling `chmod
          # -R 0777 /work` -- it genuinely worked (later inspection
          # always found /work fully 0777), but lost a real race
          # (actions/checkout writes into a freshly mkdir'd
          # _temp/_runner_file_commands/ faster than even a fast poll
          # interval can reliably catch) and, worse, confirmed live to
          # actively fight home-infra's own checks.yml security check
          # (see this file's own header comment). Removed. Fixing the
          # umask this container's own process tree inherits solves the
          # same problem at the actual source instead of polling for
          # it: anything created from here on is 0777 from the instant
          # of creation, no race, nothing to retroactively widen or
          # fight a later legitimate `chmod` over. Minimal override --
          # same ENTRYPOINT (/entrypoint.sh) and CMD (Dockerfile's own
          # ./bin/Runner.Listener run --startuptype service, passed
          # through as args below) as the image's own default, so
          # entrypoint.sh's own setup logic runs completely unchanged;
          # only the umask ahead of its exec differs.
          command = ["sh", "-c", "umask 000 && exec /entrypoint.sh \"$@\"", "sh"]
          args    = ["./bin/Runner.Listener", "run", "--startuptype", "service"]

          # GitHub App auth (2026-09-16), not a static ACCESS_TOKEN --
          # the entrypoint's own app_token.sh signs a JWT with
          # APP_PRIVATE_KEY and mints a fresh, short-lived installation
          # access token at container start, using APP_ID to identify
          # the App and APP_LOGIN (var.github_runner_owner -- a plain
          # value, not a Secret key, since it's the same public account
          # name REPO_URL below already uses) to resolve which
          # installation to mint it for.
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
          # memory bumped 2026-09-09 (128Mi->512Mi): confirmed live,
          # this exact container OOMKilled (exitCode 137) mid-`terraform
          # plan` for infra/k3s-apps -- its own state had grown
          # substantially (the Authelia rollout, its OIDC provider
          # config, new Grafana/Open WebUI resources, all added the day
          # before). Ephemeral runners don't recover from this the way
          # a normal crash-looping Pod would: the job's own GitHub
          # Actions run is permanently orphaned (the process that would
          # report back is gone), sitting "in_progress" until GitHub's
          # own dead-runner detection eventually catches up, however
          # long that takes -- had to be caught and cancelled manually.
          #
          # Bumped again same day (512Mi->1Gi): confirmed live, this
          # same limit was already insufficient again a few hours
          # later -- 21 more OOMKills, this time on infra/k3s-apps'
          # first-ever `terraform init` pulling a real provider
          # (hashicorp/aws, added for that repo's own Secrets Manager
          # cutover) on top of the same growing state, genuinely a
          # heavier `terraform init`/`plan` than this repo had ever
          # run before, not the same fixed workload the first bump was
          # sized for. Doubled rather than nudged, since "bump exactly
          # to today's peak" already proved to be exactly the trap the
          # first fix fell into -- this for_each's own single resource
          # block covers every repo's own runner, so headroom here
          # benefits all of them, not just k3s-apps'. Node capacity
          # confirmed live to have real room for this (k3s-node-2 at
          # ~43% actual memory use beforehand, kubectl top).
          #
          # cpu limit bumped 2026-09-16 (200m->1000m, matching the
          # "dind" container's own limit below): confirmed live via this
          # container's own cgroup, right after the terraform-plugin-
          # cache volume above went live, that `terraform init` re-
          # verifying a cached provider's checksum against the lock file
          # -- genuinely CPU-bound work, unlike the network-bound cold
          # download it replaces -- was hitting the CPU limit on 97% of
          # scheduling periods (`cat /sys/fs/cgroup/cpu.stat`:
          # nr_periods 2962, nr_throttled 2866, throttled_usec
          # ~292,000,000), stretching a sub-second hash+link into
          # 70s-2m12s per provider -- a cache hit that was barely faster
          # than the cold download it was meant to replace. Same
          # reasoning as the memory bumps above: this for_each's own
          # single resource block covers every repo's own runner, so
          # this benefits all of them, not just k3s-apps' Terraform
          # runs. Node capacity confirmed live to have real room for
          # this too (k3s-node-2 at 13% actual CPU use beforehand,
          # `kubectl top node`; requests stay at 10m, so this only
          # widens how much a single Pod may burst to, not what
          # scheduling reserves).
          #
          # Bumped again 2026-09-17 (1000m->2000m, the node's full 2
          # cores -- going higher than that would be a no-op ceiling on
          # this node regardless): confirmed live via aws/website's own
          # runner cgroup mid-job that the 1000m limit was still being
          # hit on ~14% of scheduling periods (nr_periods 177,
          # nr_throttled 25, throttled_usec ~822,000 of ~7.7s total CPU
          # usage) during a `terraform validate` run. Node capacity
          # confirmed live to have room (k3s-node-2 at 4% actual CPU
          # use beforehand, `kubectl top node`); requests stay at 10m,
          # so this again only widens the burst ceiling, not what
          # scheduling reserves. Note this container's own limit can
          # never usefully exceed the node's 2 physical cores, and
          # under genuine concurrent load from more than one of this
          # for_each's 8 runners at once, the real constraint becomes
          # that shared physical ceiling, not this per-Pod number.
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
        # without bound. That cache deliberately outlives Pods, so
        # nothing else ever removes an image or build layer from it;
        # confirmed live 2026-09-19 that k3s-node-2's 42GB root disk
        # climbed 39% -> 92% in ~3 days, in ~10GB steps, once every
        # repository had its own persistent cache per slot. Reuses the
        # dind image (it already ships the docker CLI) instead of adding
        # a new pinned image, and talks to the sibling dockerd over the
        # same shared socket the runner container uses. Unprivileged:
        # the socket is all it needs. Prune only ever removes what is
        # unused, so an in-flight job's images and cache are untouched;
        # the cache-warming benefit is kept for anything used recently.
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
        # both Docker's own layer cache and Terraform's own provider cache
        # were being wiped on every single run. Confirmed live for the
        # Terraform side specifically (BACKLOG.md's "k3s-apps CI" entry:
        # `terraform init` alone took 5-8 minutes on every PR check, not
        # just the first); the same "ephemeral Pod, no persisted cache"
        # mechanism applies architecturally to every repo's own
        # "docker build" CI-image step too (home-infra's checks.yml,
        # gha-common's terraform-checks.yml/terraform-apply.yml), not yet
        # separately measured. node_selector above already
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
