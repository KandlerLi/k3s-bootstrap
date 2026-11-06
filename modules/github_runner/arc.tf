# ARC: a controller plus one autoscaling runner scale set per repository. See README, "Runner design".

locals {
  arc_chart_repository = "oci://ghcr.io/actions/actions-runner-controller-charts"
  arc_chart_version    = "0.15.1"
  arc_controller_image = "0.15.1@sha256:4b51a20db717b194e2f3fa96cfe2ddcb21602811f79053c75fd1a383517b9f90"
  # The slots' image, not actions/actions-runner: host-run jobs need its node and AWS CLI. See README, "Runner design".
  arc_runner_image = "myoung34/github-runner:2.338.2-debian-trixie@sha256:ac2f72d1a1e20a62452a9bcb11488d880adacc2ad72786e920ebc3ba264cd0a4"
  dind_image       = "docker:29.9.3-dind@sha256:08a98015fce594af7c382883bea080ea206de74402a95da9dc52b6428c8cd121"

  arc_controller_service_account = "arc-controller"

  # self-hosted is not implicit on scale sets (tracker #39 probe), so it is listed like the others.
  github_runner_scale_sets = {
    for repo in var.github_runner_repositories : repo.id => {
      repository           = repo.repository
      service_account_name = try(var.github_runner_service_accounts[repo.id], null)
      memory_request       = try(var.github_runner_memory_requests[repo.id], "384Mi")
    }
  }

  node_2_placement = {
    nodeSelector = { "kubernetes.io/hostname" = "k3s-node-2" }
    tolerations = [{
      key      = "ci"
      operator = "Equal"
      value    = "github-runner"
      effect   = "NoSchedule"
    }]
  }

  restricted_pod_security_context = {
    runAsNonRoot   = true
    seccompProfile = { type = "RuntimeDefault" }
  }
  restricted_container_security_context = {
    allowPrivilegeEscalation = false
    readOnlyRootFilesystem   = true
    capabilities             = { drop = ["ALL"] }
  }
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

resource "helm_release" "arc_controller" {
  name       = "arc"
  namespace  = var.arc_controller_namespace
  repository = local.arc_chart_repository
  chart      = "gha-runner-scale-set-controller"
  version    = local.arc_chart_version

  values = [yamlencode(merge(local.node_2_placement, {
    image = { tag = local.arc_controller_image }
    serviceAccount = {
      create = true
      name   = local.arc_controller_service_account
    }
    # Its Roles then only reach ci, not every namespace.
    flags = {
      watchSingleNamespace = var.namespace
      logLevel             = "info"
    }
    podSecurityContext = local.restricted_pod_security_context
    securityContext    = local.restricted_container_security_context
    resources = {
      requests = { cpu = "10m", memory = "64Mi" }
      limits   = { memory = "256Mi" }
    }
  }))]
}

resource "kubernetes_secret_v1" "arc_github_app" {
  metadata {
    name      = "arc-github-app"
    namespace = var.namespace
  }

  data = {
    github_app_id              = var.github_runner_app_id
    github_app_installation_id = var.github_runner_app_installation_id
    github_app_private_key     = var.github_runner_app_private_key
  }

  type = "Opaque"
}

resource "helm_release" "arc_scale_set" {
  for_each = local.github_runner_scale_sets

  name       = each.key
  namespace  = var.namespace
  repository = local.arc_chart_repository
  chart      = "gha-runner-scale-set"
  version    = local.arc_chart_version

  values = [yamlencode({
    githubConfigUrl    = "https://github.com/${var.github_runner_owner}/${each.value.repository}"
    githubConfigSecret = kubernetes_secret_v1.arc_github_app.metadata[0].name
    scaleSetLabels     = ["self-hosted", "home", "debian"]
    minRunners         = 0
    maxRunners         = var.github_runner_max_runners_per_repository

    # Required with watchSingleNamespace: the chart can't find the controller itself.
    controllerServiceAccount = {
      namespace = var.arc_controller_namespace
      name      = local.arc_controller_service_account
    }

    listenerTemplate = {
      spec = merge(local.node_2_placement, {
        securityContext = local.restricted_pod_security_context
        containers = [{
          name            = "listener"
          securityContext = local.restricted_container_security_context
          resources = {
            requests = { cpu = "5m", memory = "32Mi" }
            limits   = { memory = "128Mi" }
          }
        }]
      })
    }

    template = {
      metadata = {
        labels = merge(
          { "github-runner" = "true" },
          each.value.service_account_name != null ? { "github-runner-cluster-access" = "true" } : {},
        )
      }
      spec = merge(local.node_2_placement, {
        # Only k3s-apps' runners get a ServiceAccount token: see README, "Runner design".
        automountServiceAccountToken = each.value.service_account_name != null
        serviceAccountName           = each.value.service_account_name

        initContainers = [
          # dind's container: job bind mounts resolve on its side, so it needs the runner's externals at the same path.
          {
            name         = "init-dind-externals"
            image        = local.arc_runner_image
            command      = ["cp", "-r", "/actions-runner/externals/.", "/actions-runner/tmpDir/"]
            volumeMounts = [{ name = "dind-externals", mountPath = "/actions-runner/tmpDir" }]
          },
          # A native sidecar: the runner starts only once the startupProbe sees dockerd.
          {
            name          = "dind"
            image         = local.dind_image
            restartPolicy = "Always"
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
            env             = [{ name = "DOCKER_TLS_CERTDIR", value = "" }]
            securityContext = { privileged = true }
            startupProbe = {
              exec             = { command = ["docker", "info"] }
              periodSeconds    = 5
              failureThreshold = 120
            }
            resources = {
              requests = { cpu = "100m", memory = "256Mi" }
              limits   = { cpu = "1000m", memory = "768Mi" }
            }
            volumeMounts = [
              { name = "work", mountPath = "/actions-runner/_work" },
              { name = "dind-sock", mountPath = "/var/run" },
              { name = "dind-externals", mountPath = "/actions-runner/externals" },
              { name = "terraform-plugin-cache", mountPath = "/terraform-plugin-cache" },
              { name = "dind-daemon-config", mountPath = "/etc/docker/daemon.json", subPath = "daemon.json", readOnly = true },
            ]
          },
        ]

        containers = [{
          name  = "runner"
          image = local.arc_runner_image
          # Root and umask 000 as before, against the uid mismatch with container: jobs: see README, "Runner design".
          command         = ["sh", "-c", "umask 000; exec /actions-runner/run.sh"]
          securityContext = { runAsUser = 0 }
          env = [
            { name = "RUNNER_ALLOW_RUNASROOT", value = "1" },
            { name = "DOCKER_HOST", value = "unix:///var/run/docker.sock" },
          ]
          resources = {
            requests = { cpu = "400m", memory = each.value.memory_request }
            limits   = { cpu = "2000m", memory = "1Gi" }
          }
          volumeMounts = [
            { name = "work", mountPath = "/actions-runner/_work" },
            { name = "dind-sock", mountPath = "/var/run" },
            { name = "terraform-plugin-cache", mountPath = "/terraform-plugin-cache" },
          ]
        }]

        volumes = [
          { name = "work", emptyDir = {} },
          { name = "dind-sock", emptyDir = {} },
          { name = "dind-externals", emptyDir = {} },
          { name = "terraform-plugin-cache", emptyDir = {} },
          { name = "dind-daemon-config", configMap = { name = kubernetes_config_map_v1.github_runner_dind_daemon_config.metadata[0].name } },
        ]
      })
    }
  })]

  depends_on = [helm_release.arc_controller]
}
