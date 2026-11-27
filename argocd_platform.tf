# Platform Argo CD (ADR 0037): syncs this repo's platform/ cluster-wide, by hand only. See README, "Platform Argo CD".

locals {
  argocd_platform_repo = "https://github.com/KandlerLi/k3s-bootstrap.git"
}

resource "kubernetes_namespace_v1" "argocd_platform" {
  metadata {
    name = "argocd-platform"
    labels = {
      "pod-security.kubernetes.io/enforce" = "restricted"
    }
  }
}

resource "helm_release" "argocd_platform" {
  name       = "argocd-platform"
  namespace  = kubernetes_namespace_v1.argocd_platform.metadata[0].name
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argo-cd"
  version    = "10.18.2"

  values = [yamlencode({
    # Cluster-wide on purpose: this instance creates RBAC, PVs and namespaces.
    createClusterRoles = true
    # The apps instance's release owns the Application CRDs.
    crds = { install = false }

    global = {
      image         = regex(local.image_parts, local.argocd_image)
      networkPolicy = { create = true }
    }

    # Stage 0a: headless. No login of any kind, so nobody can sync yet; UI, OIDC and notifications come in stage 0b.
    dex            = { enabled = false }
    notifications  = { enabled = false }
    applicationSet = { replicas = 0 }

    configs = {
      cm = {
        "admin.enabled"           = false
        "exec.enabled"            = false
        "users.anonymous.enabled" = false
        # Keeps its resource tracking apart from the apps instance's.
        installationID = "platform"
      }
      params = { "server.insecure" = true }
      rbac = {
        "policy.default" = ""
        "policy.csv"     = ""
      }
    }

    controller = {
      resources = {
        requests = { cpu = "50m", memory = "256Mi" }
        # Its cache holds every kind in every namespace, unlike the apps instance's.
        limits = { memory = "768Mi" }
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
}

resource "helm_release" "argocd_platform_apps" {
  name       = "argocd-platform-apps"
  namespace  = kubernetes_namespace_v1.argocd_platform.metadata[0].name
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argocd-apps"
  version    = "2.0.8"

  depends_on = [helm_release.argocd_platform]

  values = [yamlencode({
    projects = {
      platform = {
        namespace                = kubernetes_namespace_v1.argocd_platform.metadata[0].name
        description              = "This repo's platform/, synced by hand"
        sourceRepos              = [local.argocd_platform_repo]
        destinations             = [{ server = local.argocd_server, namespace = "*" }]
        clusterResourceWhitelist = [{ group = "*", kind = "*" }]
      }
    }
    # No syncPolicy.automated and no finalizer: a merge only shows up as OutOfSync (ADR 0037, Decision 5).
    applications = {
      platform-root = {
        namespace = kubernetes_namespace_v1.argocd_platform.metadata[0].name
        project   = "platform"
        source = {
          repoURL        = local.argocd_platform_repo
          targetRevision = "main"
          path           = "platform"
        }
        destination = { server = local.argocd_server, namespace = kubernetes_namespace_v1.argocd_platform.metadata[0].name }
      }
    }
  })]
}
