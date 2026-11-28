# The PVs moved to platform/storage/, synced by the platform Argo CD (ADR 0037, stage 5): Terraform forgets them, the objects and their data stay.
removed {
  from = kubernetes_persistent_volume_v1.authelia_backup
  lifecycle {
    destroy = false
  }
}

removed {
  from = kubernetes_persistent_volume_v1.stalwart_backup
  lifecycle {
    destroy = false
  }
}

removed {
  from = kubernetes_persistent_volume_v1.minecraft_backup
  lifecycle {
    destroy = false
  }
}

removed {
  from = kubernetes_persistent_volume_v1.vaultwarden_backup
  lifecycle {
    destroy = false
  }
}

removed {
  from = kubernetes_persistent_volume_v1.paperless_media
  lifecycle {
    destroy = false
  }
}

removed {
  from = kubernetes_persistent_volume_v1.paperless_export
  lifecycle {
    destroy = false
  }
}

removed {
  from = kubernetes_persistent_volume_v1.nextcloud_files
  lifecycle {
    destroy = false
  }
}

removed {
  from = kubernetes_persistent_volume_v1.nextcloud_backup
  lifecycle {
    destroy = false
  }
}

removed {
  from = kubernetes_persistent_volume_v1.sankey_export_state
  lifecycle {
    destroy = false
  }
}

removed {
  from = kubernetes_persistent_volume_v1.apps_host_path
  lifecycle {
    destroy = false
  }
}

removed {
  from = kubernetes_persistent_volume_v1.minecraft_world
  lifecycle {
    destroy = false
  }
}
