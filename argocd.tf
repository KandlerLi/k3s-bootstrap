# Argo CD: syncs k3s-apps' argocd/<app> into apps; UI on argo.jkandler.de behind Authelia. See README, "Argo CD".

locals {
  argocd_image       = "quay.io/argoproj/argocd:v3.5.6@sha256:8e5cc5bb008df8a09dba439462e58c94c55b7735888d3ebde0c25fc05e4e5335"
  argocd_redis_image = "ecr-public.aws.com/docker/library/redis:8.6.4-alpine@sha256:2cc044fc5a07c9b701f8f1255a309ae9ad7856e694ac03513bf3648c01e40763"

  # Splits name:tag@digest into the chart's {repository, tag}.
  image_parts = "^(?P<repository>[^:]+):(?P<tag>.+)$"

  argocd_server = "https://kubernetes.default.svc"
  argocd_url    = "https://argo.jkandler.de"

  # One Application per directory under k3s-apps' argocd/.
  argocd_applications = ["landing-page", "headlamp", "qbittorrent"]

  # Everything Argo CD may write in apps, by name; PVCs hold data, so Argo CD never creates or deletes one.
  argocd_apps_objects = {
    configmaps             = { api_group = "", kind = "ConfigMap", create_delete = true, names = ["landing-page-html", "qbittorrent-config"] }
    services               = { api_group = "", kind = "Service", create_delete = true, names = ["landing-page-svc", "headlamp", "qbittorrent-web-svc", "qbittorrent-peer-svc"] }
    deployments            = { api_group = "apps", kind = "Deployment", create_delete = true, names = ["landing-page", "headlamp", "qbittorrent"] }
    networkpolicies        = { api_group = "networking.k8s.io", kind = "NetworkPolicy", create_delete = true, names = ["qbittorrent"] }
    persistentvolumeclaims = { api_group = "", kind = "PersistentVolumeClaim", create_delete = false, names = ["deluge-downloads", "deluge-config"] }
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

# Traefik's ClusterIP: Argo CD reaches Authelia in-cluster instead of hairpinning through the router.
data "kubernetes_service_v1" "ingress" {
  metadata {
    name      = "ingress-svc"
    namespace = kubernetes_namespace_v1.apps.metadata[0].name
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
          name         = "Authelia"
          issuer       = "https://auth.jkandler.de"
          clientID     = "argocd"
          clientSecret = "$oidc.authelia.clientSecret"
          # Server-side PKCE (S256), which Authelia requires of every client here.
          enablePKCEAuthentication = true
          requestedScopes          = ["openid", "profile", "email", "groups"]
        })
        "resource.inclusions" = yamlencode([
          for o in local.argocd_apps_objects : { apiGroups = [o.api_group], kinds = [o.kind], clusters = ["*"] }
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

  set_sensitive = [{
    name  = "configs.secret.extra.oidc\\.authelia\\.clientSecret"
    value = local.home_infra_argocd["authelia_oidc_argocd_client_secret"]
  }]
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
      for app in local.argocd_applications : app => {
        namespace = kubernetes_namespace_v1.argocd.metadata[0].name
        project   = "k3s-apps"
        source = {
          repoURL        = "https://github.com/KandlerLi/k3s-apps.git"
          targetRevision = "main"
          path           = "argocd/${app}"
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
    verbs      = ["get", "list", "watch"]
  }
  # create can't be limited by name; changing or deleting anything else in apps stays forbidden.
  dynamic "rule" {
    for_each = { for k, o in local.argocd_apps_objects : k => o if o.create_delete }
    content {
      api_groups = [rule.value.api_group]
      resources  = [rule.key]
      verbs      = ["create"]
    }
  }
  dynamic "rule" {
    for_each = local.argocd_apps_objects
    content {
      api_groups     = [rule.value.api_group]
      resources      = [rule.key]
      resource_names = rule.value.names
      verbs          = rule.value.create_delete ? ["update", "patch", "delete"] : ["update", "patch"]
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

# The UI shows live objects through the server's own ServiceAccount; read-only, syncs run in the controller.
resource "kubernetes_role_v1" "argocd_server_apps" {
  metadata {
    name      = "argocd-server"
    namespace = kubernetes_namespace_v1.apps.metadata[0].name
  }

  rule {
    api_groups = distinct([for o in local.argocd_apps_objects : o.api_group])
    resources  = keys(local.argocd_apps_objects)
    verbs      = ["get", "list", "watch"]
  }
}

resource "kubernetes_role_binding_v1" "argocd_server_apps" {
  metadata {
    name      = "argocd-server"
    namespace = kubernetes_namespace_v1.apps.metadata[0].name
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role_v1.argocd_server_apps.metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = "argocd-server"
    namespace = kubernetes_namespace_v1.argocd.metadata[0].name
  }
}
