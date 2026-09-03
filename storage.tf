# Statically-provisioned NFS storage, cluster-scoped -- moved here from
# infra/k3s-apps' own modules/deluge and modules/open_webui (2026-09-03)
# specifically because kubernetes_persistent_volume_v1 is the one
# cluster-scoped resource type either of those modules ever needed.
# Kubernetes RBAC's resourceNames only constrains get/update/delete on
# *existing* named objects, never create -- so a namespaced Role for
# that repo's CI-applied app root could never be scoped to "only these
# three PVs" the way it can for every namespaced resource type those
# modules use. Keeping PVs here instead means that Role never needs any
# persistentvolumes verb at all. The matching PVC resources stay in
# infra/k3s-apps' own modules/deluge/modules/open_webui (they're
# namespaced, that Role covers them fine) and reference these PVs by
# their stable name string instead of a cross-module Terraform
# attribute, since the two roots have separate state.
#
# storage_class_name = "local-path" on every PV/PVC pair below -- NOT
# the empty string "" a comment here once said. Found live: an
# explicit "" gets serialized identically to "not set at all" by this
# provider (a long-standing, widely-reported terraform-provider-
# kubernetes quirk), so k3s's DefaultStorageClass admission controller
# silently injects "local-path" into the PVC regardless of what's
# written here. Matching the class name the admission controller
# injects anyway, on both sides, is the actual working fix -- the real
# local-path-provisioner is never invoked, since a suitable Available
# PV already exists and static binding always wins over dynamic
# provisioning.
#
# reclaim_policy = "Retain" on every one, not the "Delete" some
# defaults use -- critical here specifically because these PVs point at
# real, already-existing data through NFS, not disposable storage this
# cluster owns the lifecycle of. Deleting a PVC must never be able to
# touch the underlying files.
#
# The "storage" capacity/request values are nominal, not enforced --
# NFS has no concept of a Kubernetes-visible quota the way a real block
# device does. They're set generously so nothing here ever blocks on a
# false "out of space" from Kubernetes' own bookkeeping.

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

# Single PV, not split like Deluge's downloads/config -- home-infra's
# own open-webui container only ever had one bind mount
# (open_webui_data_dir -> /app/backend/data), covering the sqlite
# database, WEBUI_SECRET_KEY_FILE, and the HOME subdirectory together.
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
