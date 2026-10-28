# k3s-apps' Stalwart backup CronJob stops Stalwart for a consistent copy: see README, "RBAC".

resource "kubernetes_service_account_v1" "stalwart_backup" {
  metadata {
    name      = "stalwart-backup"
    namespace = kubernetes_namespace_v1.apps.metadata[0].name
  }
}

resource "kubernetes_role_v1" "stalwart_backup" {
  metadata {
    name      = "stalwart-backup"
    namespace = kubernetes_namespace_v1.apps.metadata[0].name
  }

  rule {
    api_groups     = ["apps"]
    resources      = ["deployments/scale"]
    resource_names = ["stalwart"]
    verbs          = ["get", "patch"]
  }
  # To wait until Stalwart's Pod is gone; list can't be limited to one label.
  rule {
    api_groups = [""]
    resources  = ["pods"]
    verbs      = ["list"]
  }
}

resource "kubernetes_role_binding_v1" "stalwart_backup" {
  metadata {
    name      = "stalwart-backup"
    namespace = kubernetes_namespace_v1.apps.metadata[0].name
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role_v1.stalwart_backup.metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account_v1.stalwart_backup.metadata[0].name
    namespace = kubernetes_service_account_v1.stalwart_backup.metadata[0].namespace
  }
}
