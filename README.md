# k3s Bootstrap

The k3s cluster's own bootstrap root: the self-hosted GitHub Actions
runner itself (`modules/github_runner`), the three cluster-scoped
`kubernetes_persistent_volume_v1` resources a namespace-scoped Role can
never be granted `create` on by name (Kubernetes RBAC's `resourceNames`
only constrains `get`/`update`/`delete` on *existing* objects), and the
Headlamp's (the cluster UI's) own RBAC (`headlamp_rbac.tf`) for the same
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
headlamp) lives in that repo's own root instead, applied
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
  reaches dockerd over a shared Unix socket volume, and dockerd listens
  on nothing else: dind is started as `dockerd
  --host=unix:///var/run/docker.sock`. Started without arguments, as
  before 2026-10-25, the image's entrypoint adds an unauthenticated
  `--host=tcp://0.0.0.0:2375` whenever `DOCKER_TLS_CERTDIR=""`, and
  dockerd then sleeps 15 s on purpose to warn about it; only the
  NetworkPolicy kept other Pods off that port.
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
  before the image's entrypoint and only then registers with GitHub, with
  no time limit. Without it, a runner came `online` while dind was still
  starting under IO load, and the first job failed with `Cannot connect
  to the Docker daemon` (2026-10-24). After a finished job the loop
  passes immediately, since dind keeps running.
- **dind retries in place.** Under the IO load after a homeserver reboot,
  dockerd gives up on its managed containerd after 15 s (`timeout
  waiting for containerd to start`). Left to Kubernetes, every such exit
  restarted the dind container with growing CrashLoopBackOff delays; on
  2026-10-25 that, plus an earlier 180 s limit in the runner's wait,
  kept runners offline for 40 minutes after a reboot. The dind container
  now runs dockerd in a shell loop that retries after 5 s; the
  containerd it already started keeps running, so a later attempt finds
  it ready. The loop forwards SIGTERM to dockerd, so Pod shutdown stays
  clean.
- **Image and registration.** The community `myoung34/github-runner`
  image, whose registration logic replaces what a persistent systemd
  service needed. GitHub App auth: the entrypoint mints a short-lived
  installation token from `APP_ID`/`APP_PRIVATE_KEY` at start (see
  `decisions.md` on why GHCR pulls stay on a classic PAT). Runner names
  are prefixed `k3s-node-2-`; labels stay `self-hosted, home, debian`, so
  no workflow needed a change. A checksum annotation of the App's private
  key rolls every runner Pod on rotation, since env from a Secret is only
  read at container start.
- **Ephemeral.** One job per runner process: after the job the listener
  exits and Kubernetes restarts the `runner` container **in the same
  Pod**, so Pod-lifetime `emptyDir`s survive from job to job. The
  container's wrapper therefore empties `/work` before every start, so
  each job begins with no checkouts, tool caches or downloaded actions
  (`_actions`) from the previous one: no leftover files breaking the
  next checkout, and no job tampering with code the next job runs.
  GitHub's recommended pattern for container runners.
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
- `sankey_export_state` is the one host-path PV: the CronJob's state
  directory on `k3s-node-1`, pinned there by node affinity. Through a
  PV the Pod mounts a PVC, which PSA `baseline` allows, and the
  directory stays where it was.
- `apps_host_path` are the six volumes that were dynamic local-path
  claims (`reclaimPolicy: Delete`) until the move to `apps`: Blocky's
  and Paperless' Postgres, Paperless' data, Bulwark, Traefik's ACME
  store and Stalwart's mail. Host paths under `/var/lib/k3s-apps-data`
  on `k3s-node-1`, `Retain`, so deleting a claim never deletes data.
- Every PV here carries a `claim_ref` naming its claim's namespace: a
  `Retain` PV released by a deleted claim only binds again to the claim
  its `claimRef` names.
- `stalwart_backup` is the write target of `k3s-apps`' Stalwart backup
  CronJob on the red HDD.
- `authelia_backup` is the write target of `k3s-apps`' Authelia backup
  CronJob, so snapshots leave the node's disk; the Paperless-ngx PVs
  (ADR 0023) hold live documents on the black HDD and nightly exports on
  the red HDD. The directories are owned by `home-infra` roles.

## Namespaces

The runners live in `ci`; Grafana, Alertmanager and kube-state-metrics
in `monitoring`; Authelia in `auth`; node-exporter in `node-exporter`;
every other k3s-apps workload in `apps` (tracker #32). `default` holds
no workloads. `ci` exists for two boundaries:

- **RBAC:** `k3s-apps-ci` has Roles only in the app namespaces, so it
  can't reach the runner Deployments or the GitHub App key in
  `github-runner-token`, which registers runners for every repository.
- **Pod Security Admission:** `ci` is labelled `enforce: privileged`,
  since `dind` needs `privileged: true`. As the other namespaces get
  `baseline`, `ci` and `node-exporter` stay the only places a privileged
  Pod can run.
  `default` enforces `baseline` (`psa.tf`); `kube-system` stays
  unlabelled, k3s' own components need it.

The runners' host-path caches are keyed by slot, not namespace, so they
survive a namespace move.

`monitoring` holds Grafana, Alertmanager and kube-state-metrics:
`enforce: baseline`, `warn: restricted` to show what `restricted` would
still reject. `k3s-apps-ci` gets a Role there for exactly the kinds those
modules create. Prometheus reaches Alertmanager and kube-state-metrics
through ServiceLB on the node's address, so the namespace doesn't
change its targets.

`auth` holds Authelia, `apps` every other k3s-apps workload, Traefik
included (both `enforce: baseline`, `warn: restricted`). `k3s-apps-ci`
has a Role in each with only the kinds its modules create. Headlamp's
ServiceAccount lives in `apps`, with cluster-wide read access only.

`node-exporter` holds only k3s-apps' node-exporter DaemonSet, which needs
the host's network, PID namespace and root filesystem; it is labelled
`enforce: privileged` like `ci`. `k3s-apps-ci` gets a Role there for
DaemonSets only.

## RBAC

Granting RBAC is itself privilege-defining: a CI ServiceAccount that
could create ServiceAccounts or (Cluster)RoleBindings could grant itself
anything up to cluster-admin. So every ServiceAccount and binding lives
here, while `k3s-apps` only references them by name in Pod specs.

- **`k3s-apps-ci`** (`main.tf`) is the ServiceAccount `k3s-apps`' CI runs
  as, for both plan and apply: plan is read-mostly, and the write gate is
  the human PR review and merge. It lives in `ci` next to its runner
  Pod. It has one Role per app namespace (`apps`, `auth`, `monitoring`,
  `node-exporter`), each covering exactly the kinds that namespace's
  modules create; for CronJobs only the CronJob objects, since their
  Jobs and Pods belong to the CronJob controller.
- **Headlamp** (`headlamp_rbac.tf`): read-only, never cluster-admin.
  Every visitor past Authelia acts as this ServiceAccount
  (`-unsafe-use-service-account-token`), so its scope is the UI's scope.
  The built-in `view` ClusterRole covers namespaced resources but not
  cluster-scoped ones or RBAC, so a ClusterRole adds those. Secrets stay
  unreadable on purpose: RBAC can't grant names without values. Node/Pod
  usage metrics come from k3s' metrics-server.
- **`stalwart-backup`** (`stalwart_backup_rbac.tf`): `get`/`patch` on
  `deployments/scale` of `stalwart` only, plus `list` on Pods in `apps`
  to wait until Stalwart has stopped (RBAC can't narrow `list` to a
  label). RocksDB is only consistent on disk while Stalwart is down, so
  k3s-apps' nightly backup CronJob scales it to 0 and back.
- **kube-state-metrics** (`kube_state_metrics_rbac.tf`): `view` plus read
  access to nodes, PersistentVolumes and namespaces, which its
  `--resources` list includes; Secrets excluded.
- **`prometheus-kubelet`** (`kubelet_metrics_rbac.tf`): `get` on
  `nodes/metrics` only, for the homeserver's Prometheus scraping each
  kubelet's `/metrics/cadvisor`. Never `nodes/proxy`, which also allows
  exec into every Pod. Prometheus runs outside the cluster, so the token
  is a long-lived ServiceAccount token Secret, copied once into Secrets
  Manager (`home-infra/prometheus`, see its runbook). To rotate it,
  `scripts/roll-out.sh apply -replace=kubernetes_secret_v1.prometheus_kubelet_token`
  and copy the new token.

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
