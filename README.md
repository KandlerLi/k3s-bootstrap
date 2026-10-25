# k3s Bootstrap

The k3s cluster's own bootstrap root: the self-hosted GitHub Actions
runner itself (`modules/github_runner`), the three cluster-scoped
`kubernetes_persistent_volume_v1` resources a namespace-scoped Role can
never be granted `create` on by name (Kubernetes RBAC's `resourceNames`
only constrains `get`/`update`/`delete` on *existing* objects), and the
Kubernetes Dashboard's own RBAC (`dashboard_rbac.tf`) for the same
underlying reason in a different shape: granting RBAC is itself
privilege-defining, so a CI-applied ServiceAccount can never be trusted
to create its own ServiceAccounts, Roles, or (Cluster)RoleBindings
without being able to grant itself arbitrary privilege. Rare changes,
applied locally with the k3s node's own cluster-admin kubeconfig —
never CI, same category as `repo-infra`/`terraform-state`.

Originally a second Terraform root nested inside [`k3s-apps`](https://github.com/KandlerLi/k3s-apps) itself
(that repo's own `bootstrap/` subdirectory); extracted into this
standalone repo (2026-09-03) to actually live alongside its real
siblings under `bootstrap/`, not inside the repo it grants access to.
Everything [`k3s-apps`](https://github.com/KandlerLi/k3s-apps) actually runs day to day (Blocky, ingress,
Grafana, home-agent, deluge, open-webui, landing-page, alertmanager,
kubernetes-dashboard) lives in that repo's own root instead, applied
via CI using the `k3s-apps-ci` ServiceAccount this repo creates
(`main.tf`).

## Prerequisites

- Terraform 1.16 or newer
- An SSH tunnel to the k3s API server and a copy of the node's own admin
  kubeconfig at `~/.kube/k3s-node-1.yaml` — see [`k3s-apps`](https://github.com/KandlerLi/k3s-apps)' own
  README for the exact tunnel + kubeconfig steps (this repo uses the
  identical setup, just far less often)
- AWS credentials for the shared `jkandler-terraform-state` S3 backend,
  same identity also used to read `secrets.tf`'s own
  `home-infra/github-runner` AWS Secrets Manager secret (the
  SOPS-to-Secrets-Manager cutover) -- no separate
  `TF_VAR_github_runner_github_token` needed any more

## Deploy

```bash
cd k3s-bootstrap
terraform init
terraform plan
terraform apply
```

Or `scripts/roll-out.sh plan`/`apply`, which does all of the above
automatically -- the SSH tunnel + kubeconfig check, and AWS credentials
for the `k3s-bootstrap-local` IAM identity from `pass` (see
[`terraform-state/README.md`](https://github.com/KandlerLi/terraform-state/blob/main/README.md)'s "k3s-bootstrap-local Identity"
section for how those get created) -- leaving an already-open tunnel
alone, closing one it started itself.

## Runner design

`modules/github_runner` runs one Deployment per repository and slot
(`github_runner_slots_per_repository`), each its own Pod with its own
`docker:dind` and docker-data cache, so a PR check and a post-merge apply
for the same repository can run at once. Not `replicas > 1` on one
Deployment: that would point two dockerd processes at one docker-data
root. History and every bug found building it: `home-infra-docs`'
`history.md` ("k3s learning cluster") and `decisions.md`.

- **Placement.** Every runner is pinned to `k3s-node-2` and tolerates its
  `ci=github-runner:NoSchedule` taint, so CI never competes with or
  endangers anything on `k3s-node-1`.
- **Docker.** A privileged `docker:dind` sidecar per Pod, not
  kaniko/rootless, so every repository's `docker build`/`docker run`
  steps work unmodified. A privileged container can escape to its node;
  that is accepted because `k3s-node-2` runs nothing else. The runner
  reaches dockerd over a shared Unix socket volume: dind's entrypoint
  opens no TCP listener just because `DOCKER_TLS_CERTDIR=""` is set.
- **MTU.** The Pod network's MTU is 1450. dockerd's bridge networks
  default to 1500, which silently black-holed response bodies of
  `container:` job steps. `daemon.json` sets `"mtu": 1450` and, via
  `default-network-opts`, the same for every bridge network dockerd
  creates, including the per-job network GitHub's runner makes.
- **Shared paths.** A `container:` job's bind-mount sources resolve on
  dockerd's filesystem, not the runner's. So `actions-runner-install`,
  `work` and the Terraform plugin cache are mounted at identical absolute
  paths in both containers, and an init container seeds
  `actions-runner-install` from the image's own `/actions-runner`
  (see "Caches" for why only once per image).
  `umask 000` ahead of the image's entrypoint keeps files written by one
  container usable by the other (the uid mismatch; it replaced a polling
  `chmod` fixer).
- **Waiting for dind.** The runner container runs `docker info` in a loop
  before the image's entrypoint and only then registers with GitHub (at
  most 180 s, then it exits and Kubernetes restarts it). Without it, a
  runner came `online` while dind was still starting under IO load, and
  the first job failed with `Cannot connect to the Docker daemon`
  (2026-10-24); dind itself restarted on `timeout waiting for containerd
  to start` during that window. After a finished job the loop passes
  immediately, since dind keeps running.
- **Image and registration.** The community `myoung34/github-runner`
  image, whose registration logic replaces what a persistent systemd
  service needed. GitHub App auth: the entrypoint mints a short-lived
  installation token from `APP_ID`/`APP_PRIVATE_KEY` at start (see
  `decisions.md` on why GHCR pulls stay on a classic PAT). Runner names
  are prefixed `k3s-node-2-`; labels stay `self-hosted, home, debian`, so
  no workflow needed a change. A checksum annotation of the App's private
  key rolls every runner Pod on rotation, since env from a Secret is only
  read at container start.
- **Ephemeral.** One job per Pod, then the Deployment starts a fresh one:
  GitHub's recommended pattern for container runners, and it removes the
  class of bug where one job's leftover files break the next checkout.
  `EPHEMERAL` is set to `true` explicitly, since the entrypoint treats any
  set value, even `false`, as true. The runner never self-updates (bump
  the image instead), never starts its own dockerd (the sidecar owns
  that), and runs as uid 0, one less identity mismatch.
- **Caches.** docker-data and the Terraform plugin cache are `host_path`
  volumes, not `emptyDir`: with ephemeral Pods, `emptyDir` wiped both on
  every job, costing 5-8 minutes of `terraform init` per PR check. Both
  are scoped per repository and slot (two dockerds, or concurrent
  Terraform writers, must never share one), created with
  `DirectoryOrCreate`. A `pruner` sidecar regularly prunes unused images
  and build cache so docker-data stays bounded; it only removes what is
  unused, never an in-flight job's data.
- **Runner install.** `actions-runner-install` (678 MB, ~11,400 files) is
  a per-slot `host_path` too. As an `emptyDir` it was re-seeded by every
  new Pod, so after a homeserver reboot all 16 Pods copied it at once
  onto the HDD-backed VM disk: 30+ minutes without CI, and the IO
  starved `k3s-node-1` too (Traefik and Authelia down for ~15 minutes on
  2026-10-24). The init container now copies only when
  `.seeded-image` doesn't match the runner image, writing the marker
  last so an interrupted copy is redone; an image bump re-seeds each
  slot once. Reusing the directory is safe: without
  `CONFIGURED_ACTIONS_RUNNER_FILES_DIR` the entrypoint deletes `.runner`
  and re-registers with `--replace` on every start. `_diag` logs older
  than 7 days are deleted at Pod start, since nothing else bounds them
  now.
- **Resources.** The runner container has a writable root filesystem on
  purpose: it is the CI job's working directory. CPU requests stay small
  (10m) while limits allow bursts; the limits were raised against real
  OOMKills and throttling as `k3s-apps`' Terraform grew. With several
  runners busy at once, `k3s-node-2`'s two cores are the real ceiling.
- **Kubernetes API access.** Only `k3s-apps`' runners get a
  ServiceAccount (`github_runner_service_accounts`), whose token is
  mounted into every container of the Pod, so its Terraform reaches the
  cluster like any in-cluster process. Every other runner has no token.
- **Network policy.** Runner Pods execute whatever a workflow says, inside
  a privileged dind, on the same flat Pod network as every app. Their
  policies allow no ingress; egress only to DNS and the public internet
  (private and link-local ranges excluded), plus, for `k3s-apps`' runners
  only, the Kubernetes API (the server node's address after kube-proxy's
  DNAT, and the ClusterIP) and Stalwart's management API. Enforced by
  k3s's embedded network-policy controller, matched by the per-slot app
  label so adding them didn't roll the Pods.

## Storage

`storage.tf` holds the statically provisioned NFS PersistentVolumes. They
live here because a PV is cluster-scoped: RBAC `resourceNames` only
constrains verbs on existing objects, never `create`, so `k3s-apps`' CI
Role could not be limited to "only these PVs". With them here, that Role
has no `persistentvolumes` verb at all. The matching PVCs stay in
`k3s-apps` and reference these PVs by name, since the two roots have
separate state.

- `storage_class_name = "local-path"` on both sides of every pair. An
  explicit `""` is serialized like "not set" by the Kubernetes provider,
  so k3s's DefaultStorageClass admission controller injects
  `local-path` anyway; matching it is the working fix. Static binding
  wins, so the local-path provisioner is never invoked.
- `reclaim_policy = "Retain"` everywhere: these PVs point at real,
  existing data, and deleting a PVC must never touch the files.
- Capacities are nominal: NFS has no Kubernetes-visible quota.
- `authelia_backup` is the write target of `k3s-apps`' Authelia backup
  CronJob, so snapshots leave the node's disk; the Paperless-ngx PVs
  (ADR 0023) hold live documents on the black HDD and nightly exports on
  the red HDD. The directories are owned by `home-infra` roles.

## RBAC

Granting RBAC is itself privilege-defining: a CI ServiceAccount that
could create ServiceAccounts or (Cluster)RoleBindings could grant itself
anything up to cluster-admin. So every ServiceAccount and binding lives
here, while `k3s-apps` only references them by name in Pod specs.

- **`k3s-apps-ci`** (`main.tf`) is the ServiceAccount `k3s-apps`' CI runs
  as, for both plan and apply: plan is read-mostly, and the write gate is
  the human PR review and merge. Its Role covers exactly the resource
  types `k3s-apps`' modules use, extended as new kinds arrive
  (`daemonsets`, `cronjobs`); for CronJobs only the CronJob objects,
  since their Jobs and Pods belong to the CronJob controller.
- **Kubernetes Dashboard** (`dashboard_rbac.tf`): read-only, never the
  upstream default of cluster-admin. The built-in `view` ClusterRole
  covers namespaced resources but not cluster-scoped ones or RBAC, so a
  ClusterRole adds those. Secrets stay unreadable on purpose: RBAC can't
  grant names without values. A namespaced Role lets the Dashboard manage
  its own key-holder/CSRF Secrets and settings ConfigMap, with unscoped
  `create` rules because those objects don't exist before its first run.
  Node/Pod usage metrics are readable too, inert without metrics-server.
- **kube-state-metrics** (`kube_state_metrics_rbac.tf`): `view` plus read
  access to nodes, PersistentVolumes and namespaces, which its
  `--resources` list includes; Secrets excluded.

## State

```text
bucket: jkandler-terraform-state
key: k3s-bootstrap/terraform.tfstate
region: eu-central-1
locking: native S3 lock file
```

## Regenerating `repositories.auto.tfvars.json`

Never hand-edit this file. It's generated by `home-infra`'s
`scripts/sync_github_runner_repositories.py` from [`repo-infra`](https://github.com/KandlerLi/repo-infra)'s
own `config.yml` (every repository with `runner: true`) — run that
script after changing which repositories have a self-hosted runner, then
`terraform plan`/`apply` here to pick it up.
