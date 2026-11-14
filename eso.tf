# External Secrets Operator and Reloader, one namespace-scoped instance each per app namespace: see README, "External Secrets" (ADR 0032).

data "aws_caller_identity" "current" {}

locals {
  eso_chart_version      = "2.15.0"
  eso_image              = "ghcr.io/external-secrets/external-secrets:v2.15.0@sha256:6888f243e5f8f7592c6d7fae2a5547c9e33531441b47b53807b9093b25a00e31"
  reloader_chart_version = "2.2.20"
  reloader_image         = "ghcr.io/stakater/reloader:v1.4.24@sha256:3ab43d3eb96c59798644bf826b0444a846c0197d22ab4b6c101c4da3e1d6ef23"

  # Same namespaces as Argo CD's; terraform-state's k3s-eso-<namespace> roles trust their external-secrets ServiceAccount.
  eso_namespaces = local.argocd_namespaces

  eso_container_security = {
    allowPrivilegeEscalation = false
    capabilities             = { drop = ["ALL"] }
    readOnlyRootFilesystem   = true
    runAsNonRoot             = true
    seccompProfile           = { type = "RuntimeDefault" }
  }
}

# CRDs in their own release, so removing one namespace's controller never deletes every ExternalSecret.
resource "helm_release" "external_secrets_crds" {
  name       = "external-secrets-crds"
  namespace  = local.argocd_namespaces.apps
  repository = "https://charts.external-secrets.io"
  chart      = "external-secrets"
  version    = local.eso_chart_version

  values = [yamlencode({
    installCRDs = true
    # Only the namespaced kinds: no instance processes cluster-scoped ones.
    crds = {
      createClusterExternalSecret = false
      createClusterSecretStore    = false
      createClusterGenerator      = false
      createClusterPushSecret     = false
      createPushSecret            = false
    }
    createOperator = false
    webhook        = { create = false }
    certController = { create = false }
    serviceAccount = { create = false }
    rbac           = { create = false }
  })]
}

resource "helm_release" "external_secrets" {
  for_each = local.eso_namespaces

  name       = "external-secrets"
  namespace  = each.value
  repository = "https://charts.external-secrets.io"
  chart      = "external-secrets"
  version    = local.eso_chart_version

  values = [yamlencode({
    installCRDs = false
    # Roles in this namespace only, no ClusterRole.
    scopedNamespace              = each.value
    scopedRBAC                   = true
    processClusterExternalSecret = false
    processClusterPushSecret     = false
    processClusterStore          = false
    processClusterGenerator      = false
    processPushSecret            = false
    openshiftFinalizers          = false
    # The validating webhook and its cert controller need cluster-scoped access; kubectl's schema check suffices here.
    webhook        = { create = false }
    certController = { create = false }
    image = {
      repository = regex(local.image_parts, local.eso_image).repository
      tag        = regex(local.image_parts, local.eso_image).tag
    }
    serviceAccount = {
      name = "external-secrets"
      # ESO's AWS JWT auth reads the role from this annotation and requests the token with audience sts.amazonaws.com.
      annotations = {
        "eks.amazonaws.com/role-arn" = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/k3s-eso-${each.key}"
      }
    }
    rbac = {
      servicebindings  = { create = false }
      aggregateToView  = false
      aggregateToEdit  = false
      aggregateToAdmin = false
    }
    securityContext = merge(local.eso_container_security, { enabled = true, runAsUser = 1000 })
    resources = {
      requests = { cpu = "10m", memory = "64Mi" }
      limits   = { memory = "256Mi" }
    }
    extraObjects = [{
      apiVersion = "external-secrets.io/v1"
      kind       = "SecretStore"
      metadata   = { name = "aws-secrets-manager", namespace = each.value }
      spec = {
        provider = {
          aws = {
            service = "SecretsManager"
            region  = "eu-central-1"
            auth    = { jwt = { serviceAccountRef = { name = "external-secrets" } } }
          }
        }
      }
    }]
  })]

  depends_on = [helm_release.external_secrets_crds]
}

resource "helm_release" "reloader" {
  for_each = local.eso_namespaces

  name       = "reloader"
  namespace  = each.value
  repository = "https://stakater.github.io/stakater-charts"
  chart      = "reloader"
  version    = local.reloader_chart_version

  values = [yamlencode({
    image = {
      repository = regex(local.image_parts, local.reloader_image).repository
      tag        = regex(local.image_parts, local.reloader_image).tag
    }
    reloader = {
      # Role in this namespace only; restarts only Deployments that opt in by annotation.
      watchGlobally = false
      autoReloadAll = false
      # Argo CD ignores the pod-template annotation this strategy sets; env-vars would fight selfHeal.
      reloadStrategy         = "annotations"
      ignoreConfigMaps       = true
      ignoreJobs             = true
      ignoreCronJobs         = true
      readOnlyRootFileSystem = true
      deployment = {
        containerSecurityContext = local.eso_container_security
        resources = {
          requests = { cpu = "10m", memory = "32Mi" }
          limits   = { memory = "128Mi" }
        }
      }
    }
  })]
}
