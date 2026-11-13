# Argo CD trial: core mode, syncs only k3s-apps' argocd/ into apps. See README, "Argo CD".

locals {
  argocd_image       = "quay.io/argoproj/argocd:v3.5.6@sha256:8e5cc5bb008df8a09dba439462e58c94c55b7735888d3ebde0c25fc05e4e5335"
  argocd_redis_image = "ecr-public.aws.com/docker/library/redis:8.6.4-alpine@sha256:2cc044fc5a07c9b701f8f1255a309ae9ad7856e694ac03513bf3648c01e40763"

  # Splits name:tag@digest into the chart's {repository, tag}.
  image_parts = "^(?P<repository>[^:]+):(?P<tag>.+)$"

  argocd_server = "https://kubernetes.default.svc"

  # Everything Argo CD may write in apps, by name.
  argocd_apps_objects = {
    configmaps  = { api_group = "", kind = "ConfigMap", names = ["landing-page-html"] }
    services    = { api_group = "", kind = "Service", names = ["landing-page-svc"] }
    deployments = { api_group = "apps", kind = "Deployment", names = ["landing-page"] }
  }
}

resource "kubernetes_namespace_v1" "argocd" {
  metadata {
    name = "argocd"
    labels = {
      "pod-security.kubernetes.io/enforce" = "restricted"
    }
  }
}

resource "helm_release" "argocd" {
  name       = "argocd"
  namespace  = kubernetes_namespace_v1.argocd.metadata[0].name
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argo-cd"
  version    = "10.11.6"

  values = [yamlencode({
    # No ClusterRoles: the controller reaches apps only through argocd_apps below.
    createClusterRoles = false
    # So removing the trial in Terraform removes the CRDs too.
    crds = { keep = false }

    global = {
      image         = regex(local.image_parts, local.argocd_image)
      networkPolicy = { create = true }
    }

    # Core mode: no API server, login or Dex; the UI runs locally, see README, "Argo CD".
    server        = { enabled = false }
    dex           = { enabled = false }
    notifications = { enabled = false }
    # The chart has no switch for it.
    applicationSet = { replicas = 0 }

    configs = {
      cm = {
        "admin.enabled" = false
        "resource.inclusions" = yamlencode([
          for o in local.argocd_apps_objects : { apiGroups = [o.api_group], kinds = [o.kind], clusters = ["*"] }
        ])
      }
      clusterCredentials = {
        in-cluster = {
          server     = local.argocd_server
          namespaces = kubernetes_namespace_v1.apps.metadata[0].name
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

# Separate release: the Application CRDs must exist before Helm can map these objects.
resource "helm_release" "argocd_apps" {
  name       = "argocd-apps"
  namespace  = kubernetes_namespace_v1.argocd.metadata[0].name
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argocd-apps"
  version    = "2.0.7"

  depends_on = [helm_release.argocd]

  values = [yamlencode({
    projects = {
      k3s-apps = {
        namespace    = kubernetes_namespace_v1.argocd.metadata[0].name
        description  = "Manifests under k3s-apps' argocd/"
        sourceRepos  = ["https://github.com/KandlerLi/k3s-apps.git"]
        destinations = [{ server = local.argocd_server, namespace = kubernetes_namespace_v1.apps.metadata[0].name }]

        clusterResourceWhitelist   = []
        namespaceResourceWhitelist = [for o in local.argocd_apps_objects : { group = o.api_group, kind = o.kind }]
      }
    }
    # No finalizer: deleting the Application leaves its objects running.
    applications = {
      landing-page = {
        namespace = kubernetes_namespace_v1.argocd.metadata[0].name
        project   = "k3s-apps"
        source = {
          repoURL        = "https://github.com/KandlerLi/k3s-apps.git"
          targetRevision = "main"
          path           = "argocd/landing-page"
        }
        destination = { server = local.argocd_server, namespace = kubernetes_namespace_v1.apps.metadata[0].name }
        syncPolicy = {
          automated = { prune = true, selfHeal = true }
        }
      }
    }
  })]
}

resource "kubernetes_role_v1" "argocd_apps" {
  metadata {
    name      = "argocd-application-controller"
    namespace = kubernetes_namespace_v1.apps.metadata[0].name
  }

  rule {
    api_groups = distinct([for o in local.argocd_apps_objects : o.api_group])
    resources  = keys(local.argocd_apps_objects)
    verbs      = ["get", "list", "watch", "create"]
  }
  # create can't be limited by name; changing or deleting anything else in apps stays forbidden.
  dynamic "rule" {
    for_each = local.argocd_apps_objects
    content {
      api_groups     = [rule.value.api_group]
      resources      = [rule.key]
      resource_names = rule.value.names
      verbs          = ["update", "patch", "delete"]
    }
  }
}

resource "kubernetes_role_binding_v1" "argocd_apps" {
  metadata {
    name      = "argocd-application-controller"
    namespace = kubernetes_namespace_v1.apps.metadata[0].name
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role_v1.argocd_apps.metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = "argocd-application-controller"
    namespace = kubernetes_namespace_v1.argocd.metadata[0].name
  }
}
