# Static NFS PVs live here, not in k3s-apps: see README, "Storage".

resource "kubernetes_persistent_volume_v1" "deluge_downloads" {
  metadata {
    name = "deluge-downloads-pv"
  }

  spec {
    capacity = {
      storage = "500Gi"
    }
    access_modes                     = ["ReadWriteMany"]
    persistent_volume_reclaim_policy = "Retain"
    storage_class_name               = "local-path"

    persistent_volume_source {
      nfs {
        server = "192.168.101.1"
        path   = "/mnt/black-hdd/downloads"
      }
    }
  }
}

resource "kubernetes_persistent_volume_v1" "deluge_config" {
  metadata {
    name = "deluge-config-pv"
  }

  spec {
    capacity = {
      storage = "1Gi"
    }
    access_modes                     = ["ReadWriteMany"]
    persistent_volume_reclaim_policy = "Retain"
    storage_class_name               = "local-path"

    persistent_volume_source {
      nfs {
        server = "192.168.101.1"
        path   = "/mnt/black-hdd/deluge-config"
      }
    }
  }
}

# Target of k3s-apps' Authelia backup CronJob, on the homeserver's disk.
resource "kubernetes_persistent_volume_v1" "authelia_backup" {
  metadata {
    name = "authelia-backup-pv"
  }

  spec {
    capacity = {
      storage = "1Gi"
    }
    access_modes                     = ["ReadWriteMany"]
    persistent_volume_reclaim_policy = "Retain"
    storage_class_name               = "local-path"

    persistent_volume_source {
      nfs {
        server = "192.168.101.1"
        path   = "/mnt/red-hdd/authelia-backup"
      }
    }
  }
}

resource "kubernetes_persistent_volume_v1" "open_webui_data" {
  metadata {
    name = "open-webui-data-pv"
  }

  spec {
    capacity = {
      storage = "5Gi"
    }
    access_modes                     = ["ReadWriteMany"]
    persistent_volume_reclaim_policy = "Retain"
    storage_class_name               = "local-path"

    persistent_volume_source {
      nfs {
        server = "192.168.101.1"
        path   = "/var/lib/open-webui"
      }
    }
  }
}

# Paperless-ngx (ADR 0023): live documents on the black HDD, exports on the red HDD.
resource "kubernetes_persistent_volume_v1" "paperless_media" {
  metadata {
    name = "paperless-media-pv"
  }

  spec {
    capacity = {
      storage = "100Gi"
    }
    access_modes                     = ["ReadWriteMany"]
    persistent_volume_reclaim_policy = "Retain"
    storage_class_name               = "local-path"

    persistent_volume_source {
      nfs {
        server = "192.168.101.1"
        path   = "/mnt/black-hdd/paperless-media"
      }
    }
  }
}

resource "kubernetes_persistent_volume_v1" "paperless_export" {
  metadata {
    name = "paperless-export-pv"
  }

  spec {
    capacity = {
      storage = "100Gi"
    }
    access_modes                     = ["ReadWriteMany"]
    persistent_volume_reclaim_policy = "Retain"
    storage_class_name               = "local-path"

    persistent_volume_source {
      nfs {
        server = "192.168.101.1"
        path   = "/mnt/red-hdd/paperless-export"
      }
    }
  }
}
