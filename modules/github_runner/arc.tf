# ARC: a controller plus one autoscaling runner scale set per repository. See README, "Runner design".

locals {
  arc_chart_repository = "oci://ghcr.io/actions/actions-runner-controller-charts"
  arc_chart_version    = "0.15.1"
  arc_controller_image = "0.15.1@sha256:4b51a20db717b194e2f3fa96cfe2ddcb21602811f79053c75fd1a383517b9f90"
  # Runs as uid 1001 without root, Docker or node: see README, "Runner design".
  arc_runner_image = "ghcr.io/actions/actions-runner:2.338.2@sha256:6d0b2d80d80f143f77dcb676e50920100bbb547e39e883454d57f45ab8c31300"
  arc_runner_uid   = 1001

  arc_controller_service_account = "arc-controller"

  # self-hosted is not implicit on scale sets (tracker #39 probe), so it is listed like the others.
  github_runner_scale_sets = {
    for repo in var.github_runner_repositories : repo.id => {
      repository     = repo.repository
      memory_request = try(var.github_runner_memory_requests[repo.id], "384Mi")
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
          contains(var.github_runner_stalwart_api_repositories, each.key) ? { "github-runner-stalwart-api" = "true" } : {},
        )
      }
      spec = merge(local.node_2_placement, {
        # No runner gets a ServiceAccount token: see README, "Runner design".
        automountServiceAccountToken = false

        securityContext = local.restricted_pod_security_context

        containers = [{
          name    = "runner"
          image   = local.arc_runner_image
          command = ["/home/runner/run.sh"]
          # The image's USER is a name, so runAsNonRoot needs the uid spelled out.
          securityContext = merge(local.restricted_container_security_context, {
            runAsUser = local.arc_runner_uid
            # The runner writes its config, logs and tool cache under /home/runner.
            readOnlyRootFilesystem = false
          })
          resources = {
            requests = { cpu = "500m", memory = each.value.memory_request }
            limits   = { cpu = "2000m", memory = "1Gi" }
          }
          volumeMounts = [{ name = "work", mountPath = "/home/runner/_work" }]
        }]

        volumes = [{ name = "work", emptyDir = {} }]
      })
    }
  })]

  depends_on = [helm_release.arc_controller]
}
