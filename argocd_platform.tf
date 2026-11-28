# Platform Argo CD (ADR 0037): syncs this repo's platform/ cluster-wide, by hand only; UI LAN-only. See README, "Platform Argo CD".

locals {
  argocd_platform_repo = "https://github.com/KandlerLi/k3s-bootstrap.git"
  argocd_platform_url  = "https://argo-platform.jkandler.de"

  # Alertmanager's webhook schema, so home-infra's ntfy relay takes it as is. Only fields that never hold quotes, or the JSON breaks.
  argocd_platform_notices = {
    out-of-sync  = { alertname = "PlatformArgoOutOfSync", severity = "warning", summary = "{{.app.metadata.name}} is OutOfSync at {{.app.status.sync.revision}}; sync it by hand on argo-platform.jkandler.de" }
    sync-running = { alertname = "PlatformArgoSyncStarted", severity = "warning", summary = "{{.app.metadata.name}}: sync started by {{.app.status.operationState.operation.initiatedBy.username}}" }
    sync-done    = { alertname = "PlatformArgoSyncSucceeded", severity = "info", summary = "{{.app.metadata.name}}: sync succeeded at {{.app.status.sync.revision}}" }
    sync-failed  = { alertname = "PlatformArgoSyncFailed", severity = "critical", summary = "{{.app.metadata.name}}: sync {{.app.status.operationState.phase}}; details on argo-platform.jkandler.de" }
  }
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
      hostAliases = [{
        ip        = data.kubernetes_service_v1.ingress.spec[0].cluster_ip
        hostnames = ["auth.jkandler.de"]
      }]
    }

    # Login only through Authelia's OIDC; the UI is LAN-only (k3s-apps' argo-platform route).
    dex            = { enabled = false }
    applicationSet = { replicas = 0 }

    configs = {
      cm = {
        url                       = local.argocd_platform_url
        "admin.enabled"           = false
        "exec.enabled"            = false
        "users.anonymous.enabled" = false
        # Keeps its resource tracking apart from the apps instance's.
        installationID = "platform"
        "oidc.config" = yamlencode({
          name         = "Authelia"
          issuer       = "https://auth.jkandler.de"
          clientID     = "argocd-platform"
          clientSecret = "$oidc.authelia.clientSecret"
          # Server-side PKCE (S256), which Authelia requires of every client here.
          enablePKCEAuthentication = true
          requestedScopes          = ["openid", "profile", "email", "groups"]
        })
      }
      # Traefik terminates TLS.
      params = { "server.insecure" = true }
      # Authelia already admits only julian; admins is a second gate.
      rbac = {
        "policy.default" = ""
        "policy.csv"     = "g, admins, role:admin"
        scopes           = "[groups]"
      }
    }

    # OutOfSync and every sync go to Julian's phone (ADR 0037, Decision 5).
    notifications = {
      enabled   = true
      argocdUrl = local.argocd_platform_url
      notifiers = {
        "service.webhook.ntfy-relay" = yamlencode({
          url     = "http://192.168.101.1:9096/webhook"
          headers = [{ name = "Content-Type", value = "application/json" }]
        })
      }
      templates = {
        for k, n in local.argocd_platform_notices : "template.platform-${k}" => yamlencode({
          webhook = {
            ntfy-relay = {
              method = "POST"
              body = jsonencode({
                status = "firing"
                alerts = [{
                  status      = "firing"
                  labels      = { alertname = n.alertname, severity = n.severity }
                  annotations = { summary = n.summary }
                }]
              })
            }
          }
        })
      }
      triggers = {
        "trigger.on-out-of-sync" = yamlencode([{
          when    = "app.status.sync.status == 'OutOfSync'"
          oncePer = "app.status.sync.revision"
          send    = ["platform-out-of-sync"]
        }])
        "trigger.on-sync-running" = yamlencode([{
          when    = "app.status.operationState.phase in ['Running']"
          oncePer = "app.status.operationState.startedAt"
          send    = ["platform-sync-running"]
        }])
        "trigger.on-sync-succeeded" = yamlencode([{
          when    = "app.status.operationState.phase in ['Succeeded']"
          oncePer = "app.status.operationState.startedAt"
          send    = ["platform-sync-done"]
        }])
        "trigger.on-sync-failed" = yamlencode([{
          when    = "app.status.operationState.phase in ['Error', 'Failed']"
          oncePer = "app.status.operationState.startedAt"
          send    = ["platform-sync-failed"]
        }])
      }
      subscriptions = [{
        recipients = ["ntfy-relay"]
        triggers   = ["on-out-of-sync", "on-sync-running", "on-sync-succeeded", "on-sync-failed"]
      }]
      resources = {
        requests = { cpu = "10m", memory = "32Mi" }
        limits   = { memory = "128Mi" }
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

  set_sensitive = [{
    name  = "configs.secret.extra.oidc\\.authelia\\.clientSecret"
    value = local.home_infra_argocd["authelia_oidc_argocd_platform_client_secret"]
  }]
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
        namespace   = kubernetes_namespace_v1.argocd_platform.metadata[0].name
        description = "This repo's platform/, synced by hand"
        # This repo, plus the public chart repos its Applications pull (platform/apps/).
        sourceRepos              = [local.argocd_platform_repo, "https://stakater.github.io/stakater-charts", "https://charts.external-secrets.io"]
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
