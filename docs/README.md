# k3s Bootstrap

The k3s cluster's own bootstrap root: the self-hosted GitHub Actions
runners (ARC, now `platform/apps/arc/`), the three cluster-scoped
`kubernetes_persistent_volume_v1` resources a namespace-scoped Role can
never be granted `create` on by name (Kubernetes RBAC's `resourceNames`
only constrains `get`/`update`/`delete` on *existing* objects), and the
Headlamp's (the cluster UI's) own RBAC (`platform/rbac/headlamp.yaml`) for the same
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
Grafana, landing-page, alertmanager,
headlamp) lives in that repo as manifests that Argo CD syncs, with
Secrets from ESO; Argo CD's, ESO's and Reloader's own setup and RBAC
live here.

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

The platform Argo CD runs GitHub's actions-runner-controller (ARC) since
stage 4 of ADR 0037 (2026-11-28): the Application `arc-controller` and one
`arc-runners-<repo>` per repository, from `platform/apps/arc/` (a base for
the scale set, an overlay per repository), plus the NetworkPolicies in
`platform/ci/`, all synced by hand. The charts come from GitHub's OCI
registry (`arc-charts` in the platform Argo CD's repositories). The GitHub
App Secret `arc-github-app` stays in this root (`arc_github_app.tf`), out of
every in-cluster role (tracker #39 for the scale-set design). There are no idle runner
Pods: each scale set has one small listener Pod, and ARC creates a fresh
runner Pod for each job and deletes it afterwards (`minRunners: 0`).
The slots before that, and every bug found building both: `home-infra-docs`'
`history.md` ("k3s learning cluster") and `decisions.md`.

- **Who gets a runner.** Only repositories whose CI needs the home
  network: today `stalwart-config` (Stalwart's in-cluster API). Everything
  else runs on GitHub-hosted runners since `gha-common` v2.0.0
  (2026-11-26), including every Docker build and `container:` job.
- **No Docker, no root.** The runner Pod is one container,
  `ghcr.io/actions/actions-runner` as uid 1001, and passes PSA
  `restricted`: no privileged `dind`, no hostPath, all capabilities
  dropped. Until 2026-11-26 every runner Pod had a privileged `dind`
  sidecar, a hostPath Terraform plugin cache and a GHCR pull-through
  cache (`registry-cache`); all three went with the Docker jobs.
- **Image.** The official image has no `node` on `PATH` and no AWS CLI,
  so jobs here use `setup-terraform` with `terraform_wrapper: false` and
  `aws-actions/configure-aws-credentials` (which brings its own node).
  `jq`, `git`, `curl` and `unzip` are in the image. ARC starts
  `/home/runner/run.sh` with its JIT config; the runner never
  self-updates (bump the image instead).
- **Concurrency.** `maxRunners` (3, in the base) is only an upper bound.
  Every runner Pod requests 500m CPU and 384Mi (an overlay can patch the
  memory for one repository);
  further Pods stay `Pending` and their jobs wait in GitHub's queue
  rather than overloading the VM (tracker #12).
- **Labels.** Every scale set registers `self-hosted, home, debian`.
  `self-hosted` is not implicit on scale sets, a probe job without it
  never started.
- **Controller.** In `arc-system` (`enforce: restricted`), with its
  listeners. `watchSingleNamespace: ci` gives it Roles in `ci` only, no
  ClusterRole. It authenticates as the `kandlerli-home-infra-runner`
  GitHub App (`arc-github-app`: App ID, installation ID, private key).
- **Placement.** Runners are pinned to `k3s-node-2` and tolerate its
  `ci=github-runner:NoSchedule` taint, so CI never competes with anything
  on `k3s-node-1`. The controller and its listeners run on `k3s-node-1`
  (control-plane node selector) since 2026-11-27: they hold the GitHub
  App key and the controller's right to create Pods in `ci`, so nothing
  on the node that runs CI code can create Pods.
- **No Kubernetes API access.** Every runner Pod has
  `automountServiceAccountToken: false`.
- **Network policy.** Runner Pods execute whatever a workflow says, on the
  same flat Pod network as every app. Their policies allow no ingress;
  egress only to DNS and the public internet (private and link-local
  ranges excluded). Enforced by k3s's embedded network-policy controller,
  for every Pod in `ci` (empty Pod selector), not only labelled runners. `stalwart-config`'s
  runners (`github-runner-stalwart-api: "true"`) also reach Stalwart's
  management API on 8080, nothing else in the cluster.

## Storage

`storage.tf` holds the statically provisioned NFS PersistentVolumes. They
live here because a PV is cluster-scoped: RBAC `resourceNames` only
constrains verbs on existing objects, never `create`, so whoever deploys
`k3s-apps` (now Argo CD's controller) could not be limited to "only these
PVs" and could mount any host or NFS path. With them here, Argo CD has no
`persistentvolumes` verb at all. The matching PVCs stay in `k3s-apps`
and reference these PVs by name.

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
- `apps_host_path` are node-local volumes under `/var/lib/k3s-apps-data`
  on `k3s-node-1`, `Retain`, so deleting a claim never deletes data. Six
  were dynamic local-path claims (`reclaimPolicy: Delete`) until the move
  to `apps`: Blocky's and Paperless' Postgres, Paperless' data, Bulwark,
  Traefik's ACME store and Stalwart's mail. Nextcloud's code/config
  (`nextcloud-html`) and Postgres came later (ADR 0033).
- Every PV here carries a `claim_ref` naming its claim's namespace: a
  `Retain` PV released by a deleted claim only binds again to the claim
  its `claimRef` names.
- `stalwart_backup` is the write target of `k3s-apps`' Stalwart backup
  CronJob on the red HDD; `minecraft_backup` the same for the Minecraft
  Pod's backup sidecar (ADR 0036). Its world is `minecraft_world`, a
  host-path volume on `k3s-node-3`, the tainted node only Minecraft runs
  on. The old `minecraft` volume on `k3s-node-1` went on 2026-11-27.
- `authelia_backup` is the write target of `k3s-apps`' Authelia backup
  CronJob, so snapshots leave the node's disk; the Paperless-ngx PVs
  (ADR 0023) hold live documents on the black HDD and nightly exports on
  the red HDD. `nextcloud_files` (ADR 0033) holds Nextcloud's live
  data directory. The directories are owned by `home-infra` roles.

## Namespaces

Since stage 1 of ADR 0037 (2026-11-28) the namespaces and their PSA labels
are manifests in `platform/namespaces/`, synced by hand by the platform Argo
CD (see "Platform Argo CD"), and annotated `Prune=false,Delete=false`, so
Argo CD never deletes one. Terraform dropped them with `removed { destroy
= false }`, and its resources name them as plain strings. Only
`argocd-platform` stays in Terraform (stage 0). On a fresh cluster the
order is: apply, which stops at the first namespace that doesn't exist yet;
sync `platform-root`; apply again.

The runners live in `ci`, the ARC controller and its listeners in
`arc-system` (`enforce: restricted`); Grafana, Alertmanager, kube-state-metrics
and Alloy in `monitoring`; Authelia in `auth`; node-exporter in `node-exporter`;
every other k3s-apps workload in `apps` (tracker #32). `default` holds
no workloads. `ci` exists for two boundaries:

- **RBAC:** nothing that runs in the app namespaces (Argo CD, ESO,
  Reloader) has a Role in `ci`, so none of it reaches the runner scale
  sets or the GitHub App key in `arc-github-app`, which registers
  runners for every repository.
- **Pod Security Admission:** `ci` enforces `restricted` (since
  2026-11-26, when the runners lost `dind`), like `auth`, `monitoring`
  (tracker #45) and `apps` (tracker #50). `node-exporter` is the only
  namespace where a privileged Pod can run.
  `default` enforces `baseline` (`platform/namespaces/`); `kube-system` stays
  unlabelled, k3s' own components need it.

`monitoring` holds Grafana, Alertmanager, kube-state-metrics and Alloy:
`enforce: restricted`. Prometheus reaches Alertmanager and kube-state-metrics
through ServiceLB on the node's address, so the namespace doesn't
change its targets.

`auth` holds Authelia, `apps` every other k3s-apps workload, Traefik
included (both `enforce: restricted`). Headlamp's
ServiceAccount lives in `apps`, with cluster-wide read access only.

`node-exporter` holds only the node-exporter DaemonSet (`platform/node-exporter/`,
synced by the platform Argo CD since stage 5b of ADR 0037; originally imported from k3s-apps), which needs the host's network, PID namespace
and root filesystem; it is labelled `enforce: privileged`.

## RBAC

Granting RBAC is itself privilege-defining: whoever could create
ServiceAccounts or (Cluster)RoleBindings could grant itself anything up
to cluster-admin. So every ServiceAccount and binding lives here, while
`k3s-apps` only references them by name in Pod specs. Since stage 2 of ADR
0037 (2026-11-28) all of the ones below are manifests in `platform/rbac/`
(Argo CD's Roles as the chart `platform/rbac/argocd-apps/`), synced by hand
by the platform Argo CD; Terraform dropped them with `removed { destroy =
false }`.
`k3s-apps`' former CI ServiceAccount `k3s-apps-ci` and its Roles went on
2026-11-15 with its Terraform.

- **Headlamp** (`headlamp.yaml`): read-only, never cluster-admin.
  Every visitor past Authelia acts as this ServiceAccount
  (`-unsafe-use-service-account-token`), so its scope is the UI's scope.
  The built-in `view` ClusterRole covers namespaced resources but not
  cluster-scoped ones or RBAC, so a ClusterRole adds those. Secrets stay
  unreadable on purpose: RBAC can't grant names without values. Node/Pod
  usage metrics come from k3s' metrics-server.
- **`stalwart-backup`** (`stalwart-backup.yaml`): `get`/`patch` on
  `deployments/scale` of `stalwart` only, plus `list` on Pods in `apps`
  to wait until Stalwart has stopped (RBAC can't narrow `list` to a
  label). RocksDB is only consistent on disk while Stalwart is down, so
  k3s-apps' nightly backup CronJob scales it to 0 and back.
- **Argo CD** (Roles: chart `platform/rbac/argocd-apps/`, synced by the
  platform Argo CD's child Application `argocd-apps-rbac` since stage 2 of
  ADR 0037): no ClusterRoles at all. In `apps`, `auth`
  and `monitoring` its application controller may read every kind it deploys
  anywhere (its cache lists each kind in each namespace), create the
  kinds it deploys in that namespace, but update, patch or delete only the
  objects named in the chart's `values.yaml` (PVCs: never delete); its
  server may only read them, plus list each namespace's Events for the UI. See
  "Argo CD".
- **kube-state-metrics** (`kube-state-metrics.yaml`): `view` plus read
  access to nodes, PersistentVolumes and namespaces, which its
  `--resources` list includes; Secrets excluded.
- **Alloy** (`alloy.yaml`): `get`/`list`/`watch` on Pods and `get`
  on `pods/log`, cluster-wide, so k3s-apps' Alloy can tail every Pod's
  logs through the API and push them to the homeserver's Loki
  (home-infra's `monitoring` role). No hostPath, no Secrets, no `exec`.
  Pod logs can contain whatever an app prints; they end up only in
  Loki, readable through Grafana.
- **`prometheus-kubelet`** (`prometheus-kubelet.yaml`): `get` on
  `nodes/metrics` only, for the homeserver's Prometheus scraping each
  kubelet's `/metrics/cadvisor`. Never `nodes/proxy`, which also allows
  exec into every Pod. Prometheus runs outside the cluster, so the token
  is a long-lived ServiceAccount token Secret, copied once into Secrets
  Manager (`home-infra/prometheus`, see its runbook). k3s fills in the
  token; the manifest carries only the type and the ServiceAccount
  annotation. To rotate it, delete the Secret
  (`kubectl -n default delete secret prometheus-kubelet-token`), sync
  `platform-root`, and copy the new token.

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
- **Scope:** the in-cluster cluster Secret restricts Argo CD to `apps`,
  `auth` and `monitoring` (`local.argocd_namespaces`) and no cluster-scoped
  resources; `resource.inclusions` and the AppProject both allow only
  the kinds in `platform/rbac/argocd-apps/values.yaml` (ConfigMap, Service,
  Deployment, CronJob, NetworkPolicy, ExternalSecret, PersistentVolumeClaim).
  The controller's Role allows changing only the named objects, the
  server's is read-only (see "RBAC"), so even an admin session in the UI
  reaches no further. A new app adds its directory to
  `local.argocd_applications` (local apply) and its object names to the
  chart's `values.yaml` (merge, then sync `argocd-apps-rbac` by hand);
  `argocd.tf` reads the kinds from that file. An Application whose directory isn't on
  k3s-apps' `main` yet only shows a path error and syncs nothing.
- **Argo CD never touches Secrets:** it has no rule on them at all. An
  app's Secrets come either from k3s-apps' Terraform or, once moved, from
  an ExternalSecret next to the app, which ESO turns into the Secret (see
  "External Secrets"). Argo CD manages only the ExternalSecret, which
  names keys, never values.
- **Data:** every app's PVCs are Argo CD's too. The Role grants no
  `delete` on PVCs (`create` stays, for a rebuilt cluster), only
  `update`/`patch` by name, and the manifests carry
  `Prune=false,Delete=false`. The source is the public k3s-apps repository, so
  no repository credential exists.
- **Sync:** automated with prune and self-heal on `main`, so the k3s-apps
  merge remains the only gate. A failed sync retries five times (30 s
  doubling to 10 min); Argo CD otherwise tries each commit only once.
- **Removing it:** see k3s-apps' docs, "Argo CD", to hand the landing
  page back to Terraform first, then delete `argocd.tf` and the route;
  the uninstall removes the CRDs too (`crds.keep = false`). The platform
  instance below uses the same CRDs, so remove it first.

## Platform Argo CD

`argocd_platform.tf` runs a second Argo CD in `argocd-platform` (ADR 0037
in home-infra-docs). It is meant to take over this repo's cluster-wide layer
stage by stage, from manifests under `platform/`. Its own install stays
here, applied locally (stage 0).

- **Login (stage 0b):** only through Authelia's OIDC (client
  `argocd-platform`, PKCE S256, `julian_only`), `role:admin` for the
  `admins` group. Admin login, Dex, exec and anonymous access stay off.
  The client secret's plaintext half is `home-infra/argocd`'s
  `authelia_oidc_argocd_platform_client_secret`, the hash is in
  `home-infra/authelia`, and it rotates with k3s-apps'
  `rotate-oidc-client-secret.sh argocd-platform`.
- **UI only from the LAN:** `argo-platform.jkandler.de` has no public DNS
  record (Blocky maps it to the homeserver). k3s-apps' route
  `argo-platform` admits only `192.168.178.0/24`, ahead of Authelia
  forward-auth with two-factor.
- **Notifications:** OutOfSync (once per revision) and every sync
  started, succeeded or failed go to home-infra's ntfy relay
  (`192.168.101.1:9096`) as Alertmanager-shaped webhooks, so they arrive
  as push like the alerts. The templates only use fields that never hold
  quotes, or the JSON would break.
- **Root:** the root Application `platform-root` points at `platform/`.
  Besides the migrated objects it holds `platform-canary`, a ConfigMap in
  `argocd-platform`. With an empty root, the UI's sync button sent no
  request at all (2026-11-28), and changing the canary tests the path
  merge → OutOfSync push → sync → started/succeeded push.
- **Cluster-wide:** `createClusterRoles = true`, unlike the apps instance.
  Its AppProject `platform` allows only this repo and every kind.
- **Sync by hand only:** no `syncPolicy.automated` and no prune, on any
  Application (ADR 0037, Decision 5). A merge to `main` shows up as
  OutOfSync and changes nothing until Julian syncs it.
- **Next to the apps instance:** the release name keeps its ClusterRoles
  apart, `installationID = "platform"` keeps the resource tracking apart,
  and `crds.install = false` leaves the Application CRDs to the apps
  instance's release. Each controller handles only the Applications in
  its own namespace.
- **Without the UI:** `k3s-tunnel`, then
  `KUBECONFIG=~/.kube/k3s-node-1.yaml argocd admin dashboard -n argocd-platform`.

## External Secrets

Since stage 3 of ADR 0037 (2026-11-28) the platform Argo CD runs the External Secrets Operator (ESO) and Reloader, for
[ADR 0032](https://github.com/KandlerLi/home-infra-docs/blob/main/docs/adr/0032-cluster-secrets-through-external-secrets.md):
Kubernetes Secrets come from AWS Secrets Manager instead of a Terraform apply.

- **One instance per namespace** (`apps`, `auth`, `monitoring`), each with
  Roles in its own namespace only and no ClusterRole, so neither can touch
  Secrets in `kube-system`, `argocd`, `ci` or `arc-system`. They are the
  Applications `external-secrets-apps|-auth|-monitoring` from
  `platform/apps/external-secrets/` (one base with chart version and values,
  an overlay per namespace), synced by hand. The CRDs (namespaced kinds
  only) are their own Application, `external-secrets-crds`, synced with
  server-side apply (too large for client-side apply), so removing one
  controller never deletes every ExternalSecret. No validating webhook: it
  needs cluster-scoped access.
- **AWS login.** Each namespace's `external-secrets` ServiceAccount stays in
  `eso.tf` (local apply), so the role ARN's account ID never enters Git and
  the trust anchor stays with the locally applied root. It carries
  `eks.amazonaws.com/role-arn` for `terraform-state`'s `k3s-eso-<namespace>`
  role; ESO exchanges a ServiceAccount token (audience `sts.amazonaws.com`,
  issuer = k3s' public issuer) for that role. The role may read only the
  Secrets Manager groups that namespace's Pods use (`terraform-state`,
  "k3s OIDC federation").
- **SecretStore** `aws-secrets-manager` in each namespace, from the
  ESO Application's values (`extraObjects`), never by the apps Argo CD: it
  binds the namespace to its role. The ExternalSecrets
  themselves live next to each app in `k3s-apps`' `argocd/`.
- **Reloader** restarts a Deployment that carries
  `secret.reloader.stakater.com/reload: <secret>` when that Secret changes,
  via a pod-template annotation (`reloadStrategy: annotations`), which Argo
  CD leaves alone. It watches Secrets only, not ConfigMaps, Jobs or CronJobs.
  Since stage 3a of ADR 0037 it is three Applications of the platform Argo CD
  (`reloader-apps`, `-auth`, `-monitoring`, from `platform/apps/reloader/`:
  one base with the chart version and values, an overlay per namespace),
  synced by hand. A version bump is one edit in the base, then three syncs
  (the Applications list can sync several at once).

## State

```text
bucket: jkandler-terraform-state
key: k3s-bootstrap/terraform.tfstate
region: eu-central-1
locking: native S3 lock file
```

## Runner repositories

`home-infra`'s `scripts/sync_github_runner_repositories.py` reads
[`repo-infra`](https://github.com/KandlerLi/repo-infra)'s `config.yml` (every repository with `runner: true`) and
writes `platform/apps/arc/scale-sets/kustomization.yaml` (never hand-edit
it). It creates an overlay for a new repository and deletes the overlay of
a removed one, but never rewrites an existing overlay, so hand edits stay
(e.g. `stalwart-config`'s label for the Stalwart API policy). Then a PR
here, merge, sync `platform-root` and the new `arc-runners-<repo>`.
