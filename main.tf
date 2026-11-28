# Bootstrap root: what stays a local apply (ADR 0037). See README.

# Namespaces and their PSA labels moved to platform/namespaces/, synced by the platform Argo CD (ADR 0037, stage 1).
removed {
  from = kubernetes_namespace_v1.ci
  lifecycle {
    destroy = false
  }
}

removed {
  from = kubernetes_namespace_v1.node_exporter
  lifecycle {
    destroy = false
  }
}

removed {
  from = kubernetes_namespace_v1.monitoring
  lifecycle {
    destroy = false
  }
}

removed {
  from = kubernetes_namespace_v1.auth
  lifecycle {
    destroy = false
  }
}

removed {
  from = kubernetes_namespace_v1.arc_system
  lifecycle {
    destroy = false
  }
}

removed {
  from = kubernetes_namespace_v1.apps
  lifecycle {
    destroy = false
  }
}

removed {
  from = kubernetes_namespace_v1.argocd
  lifecycle {
    destroy = false
  }
}

removed {
  from = kubernetes_labels.default_namespace_psa
  lifecycle {
    destroy = false
  }
}
