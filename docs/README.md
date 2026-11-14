# k3s Bootstrap

The k3s cluster's own bootstrap root: the self-hosted GitHub Actions
runners (`modules/github_runner`, ARC), the three cluster-scoped
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

After merging a PR, `scripts/update.sh plan`/`apply` switches to a fresh
`main`, refusing a dirty tree, and runs `roll-out.sh` with the same arguments.
`terraform init` there picks up changed provider and module versions.

## Runner design

`modules/github_runner` runs GitHub's actions-runner-controller (ARC)
with one runner scale set per repository in
`repositories.auto.tfvars.json` (tracker #39). There are no idle runner
Pods: each scale set has one small listener Pod, and ARC creates a fresh
runner Pod for each job and deletes it afterwards (`minRunners: 0`).
Until 2026-11 it ran two permanent Deployments ("slots") per
repository, 16 Pods that were idle most of the time. That design and
every bug found building it: `home-infra-docs`' `history.md` ("k3s
learning cluster") and `decisions.md`.

- **Concurrency.** `maxRunners` (`github_runner_max_runners_per_repository`)
  is only an upper bound. The real limit is node-2. Every runner Pod
  requests 500m CPU (runner 400m + dind 100m), so about three jobs fit on
  its two cores. Further Pods stay `Pending` and their jobs wait in
  GitHub's queue rather than overloading the VM (tracker #12). Memory
  requests come from the 7-day peak per Pod: 384Mi + 256Mi by default,
  1Gi for `k3s-apps`' runner (`github_runner_memory_requests`).
- **Labels.** Every scale set registers `self-hosted, home, debian`, so
  `runs-on` in every repository stays unchanged. `self-hosted` is not
  implicit on scale sets, a probe job without it never started.
- **Controller.** In `arc-system` (`enforce: restricted`), with its
  listeners. `watchSingleNamespace: ci` gives it Roles in `ci` only, no
  ClusterRole. It authenticates as the `kandlerli-home-infra-runner`
  GitHub App (`arc-github-app`: App ID, installation ID, private key).
  `roll-out.sh` points `DOCKER_CONFIG` at an empty directory, since Helm
  would otherwise send a stale `ghcr.io` login and get a 403 on the
  public charts.
- **Placement.** Controller, listeners and runners are pinned to
  `k3s-node-2` and tolerate its `ci=github-runner:NoSchedule` taint, so
  CI never competes with or endangers anything on `k3s-node-1`.
- **Docker.** A privileged `docker:dind` per Pod, not kaniko/rootless, so
  every repository's `docker build`/`docker run` steps work unmodified.
  A privileged container can escape to its node. That is accepted
  because `k3s-node-2` runs nothing but CI. dind is a native sidecar
  (`restartPolicy: Always` init container), and its `startupProbe` on
  `docker info` keeps the runner from starting until dockerd answers. A
  runner that came up first failed its first job with `Cannot connect to
  the Docker daemon` (2026-10-24).
- **dockerd on the Unix socket only.** dind runs `dockerd
  --host=unix:///var/run/docker.sock` on a socket volume shared with the
  runner. Without arguments, as before 2026-10-25, the image's
  entrypoint adds an unauthenticated `--host=tcp://0.0.0.0:2375` whenever
  `DOCKER_TLS_CERTDIR=""`.
- **dind retries in place.** Under heavy IO, dockerd gives up on its
  managed containerd after 15 s. Left to Kubernetes, every such exit
  meant growing CrashLoopBackOff delays, so dockerd runs in a shell loop
  that retries after 5 s and forwards SIGTERM for a clean shutdown.
- **MTU.** The Pod network's MTU is 1450. dockerd's bridge networks
  default to 1500, which silently black-holed response bodies of
  `container:` job steps. `daemon.json` sets `"mtu": 1450` and, via
  `default-network-opts`, the same for every bridge network dockerd
  creates, including the per-job network GitHub's runner makes.
- **Shared paths.** A `container:` job's bind-mount sources resolve on
  dockerd's filesystem, not the runner's. So `/actions-runner/_work`, the
  runner's externals (copied by an init container) and
  `/terraform-plugin-cache` are mounted at the same paths in both
  containers. The runner runs as root with `umask 000`, so files it
  writes stay usable by job containers running under another uid.
- **Image.** The community `myoung34/github-runner`, as for the slots,
  started with `run.sh` instead of its entrypoint, so ARC's JIT config
  registers it per job. Not the official `actions/actions-runner`: Jobs
  that run directly on the runner, without `container:` (`k3s-apps`,
  `secrets-manager`), need its `node` (`setup-terraform`'s wrapper), AWS
  CLI and Debian `apt`. The official image's Ubuntu 24.04 has neither
  `node` on `PATH` nor an `awscli` package (2026-11-01). The runner never
  self-updates (bump the image instead).
- **No caches.** Every Pod starts empty (`emptyDir` only), so no job can
  leave anything behind for the next one: no checkouts, tool caches,
  Docker images or Terraform providers. The cost, measured 2026-11-01:
  ~70 s from queued to started, plus ~76 s of `terraform init` for
  providers. A provider cache is tracked separately.
- **Kubernetes API access.** Only `k3s-apps`' runners get a
  ServiceAccount token (`github_runner_service_accounts`), so its
  Terraform reaches the cluster like any in-cluster process. Every other
  runner Pod has `automountServiceAccountToken: false`.
- **Network policy.** Runner Pods execute whatever a workflow says, inside
  a privileged dind, on the same flat Pod network as every app. Their
  policies allow no ingress; egress only to DNS and the public internet
  (private and link-local ranges excluded), plus, for `k3s-apps`' runners
  only, the Kubernetes API (the server node's address after kube-proxy's
  DNAT, and the ClusterIP), Stalwart's management API and Blocky's
  Postgres/API and Grafana for the password rotation. Enforced by k3s's
  embedded network-policy controller, selected by the Pod labels
  `github-runner: "true"` and `github-runner-cluster-access: "true"`.

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

The runners live in `ci`, the ARC controller and its listeners in
`arc-system` (`enforce: restricted`); Grafana, Alertmanager and kube-state-metrics
in `monitoring`; Authelia in `auth`; node-exporter in `node-exporter`;
every other k3s-apps workload in `apps` (tracker #32). `default` holds
no workloads. `ci` exists for two boundaries:

- **RBAC:** `k3s-apps-ci` has Roles only in the app namespaces, so it
  can't reach the runner scale sets or the GitHub App key in
  `arc-github-app`, which registers runners for every repository.
- **Pod Security Admission:** `ci` is labelled `enforce: privileged`,
  since `dind` needs `privileged: true`. As the other namespaces get
  `baseline`, `ci` and `node-exporter` stay the only places a privileged
  Pod can run. `auth`, `monitoring` (tracker #45) and `apps` (tracker
  #50) enforce `restricted`.
  `default` enforces `baseline` (`psa.tf`); `kube-system` stays
  unlabelled, k3s' own components need it.

`monitoring` holds Grafana, Alertmanager and kube-state-metrics:
`enforce: restricted`. `k3s-apps-ci` gets a Role there for exactly the kinds those
modules create. Prometheus reaches Alertmanager and kube-state-metrics
through ServiceLB on the node's address, so the namespace doesn't
change its targets.

`auth` holds Authelia, `apps` every other k3s-apps workload, Traefik
included (both `enforce: restricted`). `k3s-apps-ci`
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
- **Argo CD** (`argocd.tf`): no ClusterRoles at all. In `apps` and
  `monitoring` its application controller may list the kinds it deploys
  and create them (PVCs excepted), but update, patch or delete only the
  objects named in `local.argocd_objects` (PVCs: never delete); its
  server may only read them, plus list each namespace's Events for the UI. See
  "Argo CD".
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

## Argo CD

`argocd.tf` runs Argo CD, which deploys k3s-apps' `argocd/<app>` (one
Application each, `local.argocd_applications`, with its namespace)
instead of Terraform, with its UI on `argo.jkandler.de` (ADR 0031 in
home-infra-docs). Chart `argo-cd`, plus `argocd-apps` for the
`k3s-apps` AppProject and the Applications; it is a second
release because Helm can't map an Application before its CRD exists.

- **UI and login:** the route lives in k3s-apps and keeps Authelia
  forward-auth, limited to `user:julian`. Argo CD itself logs in only
  through Authelia's OIDC (client `argocd`, PKCE S256, `julian_only`);
  the local admin, Dex, anonymous access and exec are off. Argo CD's RBAC
  gives `role:admin` to the `admins` group and nothing to anyone else.
  The client secret's plaintext half comes from `home-infra/argocd`
  (`secrets.tf`, runbook in secrets-manager). `auth.jkandler.de` is
  pinned to Traefik's ClusterIP (`hostAliases`), like Vaultwarden.
- **Without the UI:** `k3s-tunnel`, then, with the `argocd` CLI,
  `KUBECONFIG=~/.kube/k3s-node-1.yaml argocd admin dashboard -n argocd`
  runs one locally with your kubeconfig.
- **Scope:** the in-cluster cluster Secret restricts Argo CD to `apps` and
  `monitoring` (`local.argocd_namespaces`) and no cluster-scoped
  resources; `resource.inclusions` and the AppProject both allow only
  the kinds in `local.argocd_objects` (ConfigMap, Service, Deployment,
  CronJob, NetworkPolicy, PersistentVolumeClaim).
  The controller's Role allows changing only the named objects, the
  server's is read-only (see "RBAC"), so even an admin session in the UI
  reaches no further. A new app adds its directory to
  `local.argocd_applications` and its object names to
  `local.argocd_objects`; an Application whose directory isn't on
  k3s-apps' `main` yet only shows a path error and syncs nothing.
- **Secrets stay in k3s-apps' Terraform**, with the PVCs: Argo CD has no
  rule on Secrets at all.
- **Data:** PVCs hold qBittorrent's downloads and config. The Role grants
  no `create` or `delete` on PVCs, only `update`/`patch` by name, and the
  manifests carry `Prune=false,Delete=false`. The source is the public k3s-apps repository, so
  no repository credential exists.
- **Sync:** automated with prune and self-heal on `main`, so the k3s-apps
  merge remains the only gate.
- **Removing it:** see k3s-apps' docs, "Argo CD", to hand the landing
  page back to Terraform first, then delete `argocd.tf` and the route;
  the uninstall removes the CRDs too (`crds.keep = false`).

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
