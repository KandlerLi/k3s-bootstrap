# Static NFS PVs live here, not in k3s-apps: see README, "Storage".

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

    # Pre-bound to the claim in auth, so a Retain PV released by its old default claim binds again.
    claim_ref {
      namespace = "auth"
      name      = "authelia-backup"
    }
  }
}

# Target of k3s-apps' Stalwart backup CronJob, on the homeserver's red HDD.
resource "kubernetes_persistent_volume_v1" "stalwart_backup" {
  metadata {
    name = "stalwart-backup-pv"
  }

  spec {
    capacity = {
      storage = "20Gi"
    }
    access_modes                     = ["ReadWriteMany"]
    persistent_volume_reclaim_policy = "Retain"
    storage_class_name               = "local-path"

    persistent_volume_source {
      nfs {
        server = "192.168.101.1"
        path   = "/mnt/red-hdd/stalwart-backup"
      }
    }

    claim_ref {
      namespace = "apps"
      name      = "stalwart-backup"
    }
  }
}

# Target of k3s-apps' Vaultwarden backup CronJob, on the homeserver's red HDD.
resource "kubernetes_persistent_volume_v1" "vaultwarden_backup" {
  metadata {
    name = "vaultwarden-backup-pv"
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
        path   = "/mnt/red-hdd/vaultwarden-backup"
      }
    }

    claim_ref {
      namespace = "apps"
      name      = "vaultwarden-backup"
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

    claim_ref {
      namespace = "apps"
      name      = "paperless-media"
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

    claim_ref {
      namespace = "apps"
      name      = "paperless-export"
    }
  }
}

# Nextcloud on k3s (ADR 0033): for now the test instance's empty data directory (home-infra's nextcloud_storage role).
resource "kubernetes_persistent_volume_v1" "nextcloud_data" {
  metadata {
    name = "nextcloud-data-pv"
  }

  spec {
    capacity = {
      storage = "1Ti"
    }
    access_modes                     = ["ReadWriteMany"]
    persistent_volume_reclaim_policy = "Retain"
    storage_class_name               = "local-path"

    persistent_volume_source {
      nfs {
        server = "192.168.101.1"
        path   = "/mnt/black-hdd/nextcloud-k3s-test"
      }
    }

    claim_ref {
      namespace = "apps"
      name      = "nextcloud-data"
    }
  }
}

# Nextcloud's live data directory (ADR 0033), mounted from the cutover on; AIO's until then.
resource "kubernetes_persistent_volume_v1" "nextcloud_files" {
  metadata {
    name = "nextcloud-files-pv"
  }

  spec {
    capacity = {
      storage = "1Ti"
    }
    access_modes                     = ["ReadWriteMany"]
    persistent_volume_reclaim_policy = "Retain"
    storage_class_name               = "local-path"

    persistent_volume_source {
      nfs {
        server = "192.168.101.1"
        path   = "/mnt/black-hdd/nextcloud"
      }
    }

    claim_ref {
      namespace = "apps"
      name      = "nextcloud-files"
    }
  }
}

# Target of k3s-apps' Nextcloud backup CronJob (pg_dump + config.php), on the red HDD (ADR 0033).
resource "kubernetes_persistent_volume_v1" "nextcloud_backup" {
  metadata {
    name = "nextcloud-backup-pv"
  }

  spec {
    capacity = {
      storage = "20Gi"
    }
    access_modes                     = ["ReadWriteMany"]
    persistent_volume_reclaim_policy = "Retain"
    storage_class_name               = "local-path"

    persistent_volume_source {
      nfs {
        server = "192.168.101.1"
        path   = "/mnt/red-hdd/nextcloud-backup"
      }
    }

    claim_ref {
      namespace = "apps"
      name      = "nextcloud-backup"
    }
  }
}

# sankey-export's state on k3s-node-1's disk. A PV, so the Pod itself has no hostPath volume (PSA baseline).
resource "kubernetes_persistent_volume_v1" "sankey_export_state" {
  metadata {
    name = "sankey-export-state-pv"
  }

  spec {
    capacity = {
      storage = "1Gi"
    }
    access_modes                     = ["ReadWriteOnce"]
    persistent_volume_reclaim_policy = "Retain"
    storage_class_name               = "local-path"

    persistent_volume_source {
      host_path {
        path = "/var/lib/k3s-sankey-export"
        type = "Directory"
      }
    }

    # The data lives on this node only.
    node_affinity {
      required {
        node_selector_term {
          match_expressions {
            key      = "kubernetes.io/hostname"
            operator = "In"
            values   = ["k3s-node-1"]
          }
        }
      }
    }

    claim_ref {
      namespace = "apps"
      name      = "sankey-export-state"
    }
  }
}

# Formerly dynamic local-path volumes (reclaim Delete); static and Retain since the move to apps. See README, "Storage".
locals {
  apps_host_path_volumes = {
    blocky-postgres    = "256Mi"
    bulwark            = "1Gi"
    ingress-acme       = "128Mi"
    nextcloud-html     = "10Gi"
    nextcloud-postgres = "5Gi"
    paperless-data     = "5Gi"
    paperless-postgres = "2Gi"
    stalwart           = "5Gi"
  }
}

resource "kubernetes_persistent_volume_v1" "apps_host_path" {
  for_each = local.apps_host_path_volumes

  metadata {
    name = "${each.key}-pv"
  }

  spec {
    capacity = {
      storage = each.value
    }
    access_modes                     = ["ReadWriteOnce"]
    persistent_volume_reclaim_policy = "Retain"
    storage_class_name               = "local-path"

    persistent_volume_source {
      host_path {
        path = "/var/lib/k3s-apps-data/${each.key}"
        type = "DirectoryOrCreate"
      }
    }

    claim_ref {
      namespace = "apps"
      name      = each.key
    }

    node_affinity {
      required {
        node_selector_term {
          match_expressions {
            key      = "kubernetes.io/hostname"
            operator = "In"
            values   = ["k3s-node-1"]
          }
        }
      }
    }
  }
}
