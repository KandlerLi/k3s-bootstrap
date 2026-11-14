# Argo CD: syncs k3s-apps' argocd/<app> into apps, auth and monitoring; UI on argo.jkandler.de behind Authelia. See README, "Argo CD".

locals {
  argocd_image       = "quay.io/argoproj/argocd:v3.5.6@sha256:8e5cc5bb008df8a09dba439462e58c94c55b7735888d3ebde0c25fc05e4e5335"
  argocd_redis_image = "ecr-public.aws.com/docker/library/redis:8.6.4-alpine@sha256:2cc044fc5a07c9b701f8f1255a309ae9ad7856e694ac03513bf3648c01e40763"

  # Splits name:tag@digest into the chart's {repository, tag}.
  image_parts = "^(?P<repository>[^:]+):(?P<tag>.+)$"

  argocd_server = "https://kubernetes.default.svc"
  argocd_url    = "https://argo.jkandler.de"

  # One Application per directory under k3s-apps' argocd/, with its namespace.
  argocd_applications = {
    landing-page       = "apps"
    headlamp           = "apps"
    qbittorrent        = "apps"
    bulwark            = "apps"
    home-agent         = "apps"
    open-webui         = "apps"
    sankey-export      = "apps"
    vaultwarden        = "apps"
    paperless          = "apps"
    stalwart           = "apps"
    ingress            = "apps"
    blocky             = "apps"
    authelia           = "auth"
    alertmanager       = "monitoring"
    grafana            = "monitoring"
    kube-state-metrics = "monitoring"
  }

  argocd_namespaces = {
    apps       = kubernetes_namespace_v1.apps.metadata[0].name
    auth       = kubernetes_namespace_v1.auth.metadata[0].name
    monitoring = kubernetes_namespace_v1.monitoring.metadata[0].name
  }

  # Everything Argo CD may write, per namespace and by name; PVCs hold data, so Argo CD never deletes one.
  argocd_objects = {
    apps = {
      configmaps             = { api_group = "", kind = "ConfigMap", create = true, delete = true, names = ["landing-page-html", "qbittorrent-config", "nextcloud-tools-source", "ingress-static-config", "ingress-dynamic-config"] }
      services               = { api_group = "", kind = "Service", create = true, delete = true, names = ["landing-page-svc", "headlamp", "qbittorrent-web-svc", "qbittorrent-peer-svc", "bulwark-svc", "home-agent-svc", "open-webui-svc", "vaultwarden-svc", "paperless-svc", "stalwart-smtp", "stalwart-internal", "ingress-svc", "blocky-svc"] }
      deployments            = { api_group = "apps", kind = "Deployment", create = true, delete = true, names = ["landing-page", "headlamp", "qbittorrent", "bulwark", "home-agent", "open-webui", "vaultwarden", "paperless", "stalwart", "ingress", "blocky"] }
      cronjobs               = { api_group = "batch", kind = "CronJob", create = true, delete = true, names = ["sankey-export", "vaultwarden-backup", "paperless-export", "stalwart-backup"] }
      networkpolicies        = { api_group = "networking.k8s.io", kind = "NetworkPolicy", create = true, delete = true, names = ["qbittorrent", "vaultwarden"] }
      persistentvolumeclaims = { api_group = "", kind = "PersistentVolumeClaim", create = true, delete = false, names = ["deluge-downloads", "deluge-config", "blocky-postgres", "bulwark", "ingress-acme", "open-webui-data", "paperless-data", "paperless-postgres", "paperless-media", "paperless-export", "sankey-export-state", "stalwart", "stalwart-backup", "vaultwarden-data", "vaultwarden-backup"] }
    }
    auth = {
      services               = { api_group = "", kind = "Service", create = true, delete = true, names = ["authelia-svc"] }
      deployments            = { api_group = "apps", kind = "Deployment", create = true, delete = true, names = ["authelia"] }
      cronjobs               = { api_group = "batch", kind = "CronJob", create = true, delete = true, names = ["authelia-backup"] }
      persistentvolumeclaims = { api_group = "", kind = "PersistentVolumeClaim", create = true, delete = false, names = ["authelia-data", "authelia-redis", "authelia-backup"] }
    }
    monitoring = {
      configmaps  = { api_group = "", kind = "ConfigMap", create = true, delete = true, names = ["grafana-dashboard-provider", "grafana-dashboards"] }
      services    = { api_group = "", kind = "Service", create = true, delete = true, names = ["alertmanager-svc", "grafana-svc", "kube-state-metrics-svc"] }
      deployments = { api_group = "apps", kind = "Deployment", create = true, delete = true, names = ["alertmanager", "grafana", "kube-state-metrics"] }
    }
  }

  # Every kind Argo CD handles in any namespace.
  argocd_kinds = distinct(flatten([
    for objects in values(local.argocd_objects) : [for o in values(objects) : { api_group = o.api_group, kind = o.kind }]
  ]))

  # Argo CD's cache lists every kind above in every namespace it manages, so reading must cover them all everywhere.
  argocd_read = {
    api_groups = distinct([for k in local.argocd_kinds : k.api_group])
    resources  = distinct(flatten([for objects in values(local.argocd_objects) : keys(objects)]))
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
        destinations = [for ns in values(local.argocd_namespaces) : { server = local.argocd_server, namespace = ns }]

        clusterResourceWhitelist   = []
        namespaceResourceWhitelist = [for k in local.argocd_kinds : { group = k.api_group, kind = k.kind }]
      }
    }
    # No finalizer: deleting the Application leaves its objects running.
    applications = {
      for app, ns in local.argocd_applications : app => {
        namespace = kubernetes_namespace_v1.argocd.metadata[0].name
        project   = "k3s-apps"
        source = {
          repoURL        = "https://github.com/KandlerLi/k3s-apps.git"
          targetRevision = "main"
          path           = "argocd/${app}"
        }
        destination = { server = local.argocd_server, namespace = local.argocd_namespaces[ns] }
        syncPolicy = {
          automated = { prune = true, selfHeal = true }
          # Automated sync tries each commit once; retries let a transient failure (RBAC not applied yet) heal itself.
          retry = {
            limit   = 5
            backoff = { duration = "30s", factor = 2, maxDuration = "10m" }
          }
        }
      }
    }
  })]
}

moved {
  from = kubernetes_role_v1.argocd_apps
  to   = kubernetes_role_v1.argocd_controller["apps"]
}

moved {
  from = kubernetes_role_binding_v1.argocd_apps
  to   = kubernetes_role_binding_v1.argocd_controller["apps"]
}

moved {
  from = kubernetes_role_v1.argocd_server_apps
  to   = kubernetes_role_v1.argocd_server["apps"]
}

moved {
  from = kubernetes_role_binding_v1.argocd_server_apps
  to   = kubernetes_role_binding_v1.argocd_server["apps"]
}

resource "kubernetes_role_v1" "argocd_controller" {
  for_each = local.argocd_objects

  metadata {
    name      = "argocd-application-controller"
    namespace = local.argocd_namespaces[each.key]
  }

  rule {
    api_groups = local.argocd_read.api_groups
    resources  = local.argocd_read.resources
    verbs      = ["get", "list", "watch"]
  }
  # create can't be limited by name; changing or deleting anything else in the namespace stays forbidden.
  dynamic "rule" {
    for_each = { for k, o in each.value : k => o if o.create }
    content {
      api_groups = [rule.value.api_group]
      resources  = [rule.key]
      verbs      = ["create"]
    }
  }
  dynamic "rule" {
    for_each = each.value
    content {
      api_groups     = [rule.value.api_group]
      resources      = [rule.key]
      resource_names = rule.value.names
      verbs          = rule.value.delete ? ["update", "patch", "delete"] : ["update", "patch"]
    }
  }
}

resource "kubernetes_role_binding_v1" "argocd_controller" {
  for_each = local.argocd_objects

  metadata {
    name      = "argocd-application-controller"
    namespace = local.argocd_namespaces[each.key]
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role_v1.argocd_controller[each.key].metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = "argocd-application-controller"
    namespace = kubernetes_namespace_v1.argocd.metadata[0].name
  }
}

# The UI shows live objects through the server's own ServiceAccount; read-only, syncs run in the controller.
resource "kubernetes_role_v1" "argocd_server" {
  for_each = local.argocd_objects

  metadata {
    name      = "argocd-server"
    namespace = local.argocd_namespaces[each.key]
  }

  rule {
    api_groups = local.argocd_read.api_groups
    resources  = local.argocd_read.resources
    verbs      = ["get", "list", "watch"]
  }
  # The UI's Events tab per resource.
  rule {
    api_groups = [""]
    resources  = ["events"]
    verbs      = ["list"]
  }
}

resource "kubernetes_role_binding_v1" "argocd_server" {
  for_each = local.argocd_objects

  metadata {
    name      = "argocd-server"
    namespace = local.argocd_namespaces[each.key]
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role_v1.argocd_server[each.key].metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = "argocd-server"
    namespace = kubernetes_namespace_v1.argocd.metadata[0].name
  }
}
