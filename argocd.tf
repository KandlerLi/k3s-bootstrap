# Argo CD: syncs k3s-apps' argocd/<app> into apps, auth and monitoring; UI on argo.jkandler.de behind Authelia. See README, "Argo CD".

locals {
  argocd_image       = "quay.io/argoproj/argocd:v3.6.2@sha256:bbcc3b6e79c5963439bdc5170f6e20a52365b41878133fac5ce8d6810d2641dc"
  argocd_redis_image = "ecr-public.aws.com/docker/library/redis:8.10.3-alpine@sha256:7958cfbb9d152f87dadfbc89f1b0b15938f0b81ff8982feb327476f4911935c3"

  # Splits name:tag@digest into the chart's {repository, tag}.
  image_parts = "^(?P<repository>[^:]+):(?P<tag>.+)$"

  argocd_server = "https://kubernetes.default.svc"
  argocd_url    = "https://argo.jkandler.de"


  argocd_namespaces = {
    apps       = "apps"
    auth       = "auth"
    monitoring = "monitoring"
  }

  # Everything Argo CD may write, per namespace and by name: the platform Argo CD's chart renders the Roles from it (ADR 0037, stage 2).
  argocd_objects = yamldecode(file("${path.module}/platform/rbac/argocd-apps/values.yaml")).objects

  # Every kind Argo CD handles in any namespace.
  argocd_kinds = distinct(flatten([
    for objects in values(local.argocd_objects) : [for o in values(objects) : { api_group = o.apiGroup, kind = o.kind }]
  ]))

}

# Traefik's ClusterIP: Argo CD reaches Authelia in-cluster instead of hairpinning through the router.
data "kubernetes_service_v1" "ingress" {
  metadata {
    name      = "ingress-svc"
    namespace = "apps"
  }
}

resource "helm_release" "argocd" {
  name       = "argocd"
  namespace  = "argocd"
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argo-cd"
  version    = "10.18.2"

  values = [yamlencode({
    # No ClusterRoles: the controller reaches apps only through the Roles from platform/rbac/argocd-apps/.
    createClusterRoles = false
    # The Application CRDs serve both Argo CD instances: never deleted, neither by Helm nor by Argo CD (ADR 0037, stage 6).
    crds = {
      keep = true
      annotations = {
        "argocd.argoproj.io/sync-options" = "ServerSideApply=true,Prune=false,Delete=false"
      }
    }

    global = {
      image         = regex(local.image_parts, local.argocd_image)
      networkPolicy = { create = true }
      hostAliases = [{
        ip        = data.kubernetes_service_v1.ingress.spec[0].cluster_ip
        hostnames = ["auth.jkandler.de"]
      }]
    }

    # Login only through Authelia's OIDC, so no Dex and no local admin.
    dex           = { enabled = false }
    notifications = { enabled = false }
    # The chart has no switch for it.
    applicationSet = { replicas = 0 }

    configs = {
      cm = {
        url             = local.argocd_url
        "admin.enabled" = false
        "oidc.config" = yamlencode({
          name     = "Authelia"
          issuer   = "https://auth.jkandler.de"
          clientID = "argocd"
          # A key of argocd-oidc-authelia below, so these values hold no secret.
          clientSecret = "$argocd-oidc-authelia:clientSecret"
          # Server-side PKCE (S256), which Authelia requires of every client here.
          enablePKCEAuthentication = true
          requestedScopes          = ["openid", "profile", "email", "groups"]
        })
        "resource.inclusions" = yamlencode([
          for k in local.argocd_kinds : { apiGroups = [k.api_group], kinds = [k.kind], clusters = ["*"] }
        ])
      }
      # Traefik terminates TLS.
      params = { "server.insecure" = true }
      # Authelia already admits only julian; admins is a second gate.
      rbac = {
        "policy.default" = ""
        "policy.csv"     = "g, admins, role:admin"
        scopes           = "[groups]"
      }
      clusterCredentials = {
        in-cluster = {
          server     = local.argocd_server
          namespaces = join(",", values(local.argocd_namespaces))
          config     = { tlsClientConfig = { insecure = false } }
        }
      }
    }

    controller = {
      resources = {
        requests = { cpu = "50m", memory = "256Mi" }
        limits   = { memory = "512Mi" }
      }
    }
    server = {
      resources = {
        requests = { cpu = "10m", memory = "64Mi" }
        limits   = { memory = "256Mi" }
      }
    }
    repoServer = {
      resources = {
        requests = { cpu = "10m", memory = "64Mi" }
        limits   = { memory = "256Mi" }
      }
    }
    redis = {
      image = regex(local.image_parts, local.argocd_redis_image)
      resources = {
        requests = { cpu = "10m", memory = "32Mi" }
        limits   = { memory = "128Mi" }
      }
    }
    redisSecretInit = {
      resources = {
        requests = { cpu = "10m", memory = "32Mi" }
        limits   = { memory = "128Mi" }
      }
    }
  })]

  depends_on = [kubernetes_secret_v1.argocd_oidc_authelia]
}

# The OIDC client secret stays in this local root, like arc-github-app; Argo CD reads Secrets labelled part-of argocd.
resource "kubernetes_secret_v1" "argocd_oidc_authelia" {
  metadata {
    name      = "argocd-oidc-authelia"
    namespace = "argocd"
    labels = {
      "app.kubernetes.io/part-of" = "argocd"
    }
  }

  data = {
    clientSecret = local.home_infra_argocd["authelia_oidc_argocd_client_secret"]
  }

  type = "Opaque"
}

# Its AppProject and Applications moved to platform/rbac/argocd-apps/ (templates/applications.yaml), synced by the platform Argo CD (ADR 0037, stage 6b).
removed {
  from = helm_release.argocd_apps
  lifecycle {
    destroy = false
  }
}

# Its Roles moved to platform/rbac/argocd-apps/, synced by the platform Argo CD (ADR 0037, stage 2).
removed {
  from = kubernetes_role_v1.argocd_controller
  lifecycle {
    destroy = false
  }
}

removed {
  from = kubernetes_role_binding_v1.argocd_controller
  lifecycle {
    destroy = false
  }
}

removed {
  from = kubernetes_role_v1.argocd_server
  lifecycle {
    destroy = false
  }
}

removed {
  from = kubernetes_role_binding_v1.argocd_server
  lifecycle {
    destroy = false
  }
}
