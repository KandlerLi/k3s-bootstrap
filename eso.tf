# The External Secrets Operator's ServiceAccounts (the AWS trust anchor); ESO and Reloader themselves are in platform/apps/. See README, "External Secrets" (ADR 0032).

data "aws_caller_identity" "current" {}

locals {
  # Same namespaces as Argo CD's; terraform-state's k3s-eso-<namespace> roles trust their external-secrets ServiceAccount.
  eso_namespaces = local.argocd_namespaces
}

# The AWS trust anchor stays in this local root: the role ARN holds the account ID, which never enters Git.
# ESO itself (controller, SecretStore, CRDs) is in platform/apps/external-secrets/, synced by the platform Argo CD (ADR 0037, stage 3b).
resource "kubernetes_service_account_v1" "eso" {
  for_each = local.eso_namespaces

  metadata {
    name      = "external-secrets"
    namespace = each.value
    annotations = {
      # ESO's AWS JWT auth reads the role from this annotation and requests the token with audience sts.amazonaws.com.
      "eks.amazonaws.com/role-arn" = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/k3s-eso-${each.key}"
    }
  }
}

# Created by the former external-secrets Helm release.
import {
  for_each = local.eso_namespaces
  to       = kubernetes_service_account_v1.eso[each.key]
  id       = "${each.value}/external-secrets"
}

removed {
  from = helm_release.external_secrets
  lifecycle {
    destroy = false
  }
}

removed {
  from = helm_release.external_secrets_crds
  lifecycle {
    destroy = false
  }
}

# Reloader moved to platform/apps/reloader/, synced by the platform Argo CD (ADR 0037, stage 3a).
removed {
  from = helm_release.reloader
  lifecycle {
    destroy = false
  }
}
