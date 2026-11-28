# k3s-apps' Alloy tails every Pod's logs through the API: read Pods and pods/log only, no Secrets. See README, "RBAC".

resource "kubernetes_service_account_v1" "alloy" {
  metadata {
    name      = "alloy"
    namespace = "monitoring"
  }
}

resource "kubernetes_cluster_role_v1" "alloy_pod_logs" {
  metadata {
    name = "alloy-pod-logs"
  }

  rule {
    api_groups = [""]
    resources  = ["pods"]
    verbs      = ["get", "list", "watch"]
  }

  rule {
    api_groups = [""]
    resources  = ["pods/log"]
    verbs      = ["get"]
  }
}

resource "kubernetes_cluster_role_binding_v1" "alloy_pod_logs" {
  metadata {
    name = "alloy-pod-logs"
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role_v1.alloy_pod_logs.metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account_v1.alloy.metadata[0].name
    namespace = kubernetes_service_account_v1.alloy.metadata[0].namespace
  }
}
