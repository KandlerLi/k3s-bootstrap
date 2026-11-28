# node-exporter moved to platform/node-exporter/, synced by the platform Argo CD (ADR 0037, stage 5b).
removed {
  from = kubernetes_daemon_set_v1.node_exporter
  lifecycle {
    destroy = false
  }
}
