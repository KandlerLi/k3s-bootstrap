# Moved to platform/rbac/, synced by the platform Argo CD (ADR 0037, stage 2): Terraform forgets them, the objects stay.
removed {
  from = kubernetes_service_account_v1.headlamp
  lifecycle {
    destroy = false
  }
}

removed {
  from = kubernetes_cluster_role_binding_v1.headlamp_view
  lifecycle {
    destroy = false
  }
}

removed {
  from = kubernetes_cluster_role_v1.headlamp_cluster_read
  lifecycle {
    destroy = false
  }
}

removed {
  from = kubernetes_cluster_role_binding_v1.headlamp_cluster_read
  lifecycle {
    destroy = false
  }
}

removed {
  from = kubernetes_cluster_role_v1.headlamp_metrics
  lifecycle {
    destroy = false
  }
}

removed {
  from = kubernetes_cluster_role_binding_v1.headlamp_metrics
  lifecycle {
    destroy = false
  }
}

removed {
  from = kubernetes_service_account_v1.kube_state_metrics_monitoring
  lifecycle {
    destroy = false
  }
}

removed {
  from = kubernetes_cluster_role_binding_v1.kube_state_metrics_view
  lifecycle {
    destroy = false
  }
}

removed {
  from = kubernetes_cluster_role_v1.kube_state_metrics_cluster_read
  lifecycle {
    destroy = false
  }
}

removed {
  from = kubernetes_cluster_role_binding_v1.kube_state_metrics_cluster_read
  lifecycle {
    destroy = false
  }
}

removed {
  from = kubernetes_service_account_v1.alloy
  lifecycle {
    destroy = false
  }
}

removed {
  from = kubernetes_cluster_role_v1.alloy_pod_logs
  lifecycle {
    destroy = false
  }
}

removed {
  from = kubernetes_cluster_role_binding_v1.alloy_pod_logs
  lifecycle {
    destroy = false
  }
}

removed {
  from = kubernetes_service_account_v1.prometheus_kubelet
  lifecycle {
    destroy = false
  }
}

removed {
  from = kubernetes_cluster_role_v1.kubelet_metrics_read
  lifecycle {
    destroy = false
  }
}

removed {
  from = kubernetes_cluster_role_binding_v1.prometheus_kubelet
  lifecycle {
    destroy = false
  }
}

removed {
  from = kubernetes_secret_v1.prometheus_kubelet_token
  lifecycle {
    destroy = false
  }
}

removed {
  from = kubernetes_service_account_v1.stalwart_backup
  lifecycle {
    destroy = false
  }
}

removed {
  from = kubernetes_role_v1.stalwart_backup
  lifecycle {
    destroy = false
  }
}

removed {
  from = kubernetes_role_binding_v1.stalwart_backup
  lifecycle {
    destroy = false
  }
}
