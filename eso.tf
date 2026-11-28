# External Secrets Operator, one namespace-scoped instance per app namespace: see README, "External Secrets" (ADR 0032). Reloader is in platform/apps/reloader/.

data "aws_caller_identity" "current" {}

locals {
  eso_chart_version = "2.15.0"
  eso_image         = "ghcr.io/external-secrets/external-secrets:v2.15.0@sha256:6888f243e5f8f7592c6d7fae2a5547c9e33531441b47b53807b9093b25a00e31"

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

# Reloader moved to platform/apps/reloader/, synced by the platform Argo CD (ADR 0037, stage 3a).
removed {
  from = helm_release.reloader
  lifecycle {
    destroy = false
  }
}
