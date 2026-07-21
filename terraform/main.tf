###############################################################################
# Variables
###############################################################################

variable "project_id" {
  description = "GCP project ID"
  type        = string
  default     = "hermes-agent-github-actions"
}

variable "region" {
  description = "GCP region"
  type        = string
  default     = "us-central1"
}

variable "zone" {
  description = "GCP zone for node pools"
  type        = string
  default     = "us-central1-a"
}

variable "cluster_name" {
  description = "GKE cluster name"
  type        = string
  default     = "gha-runners"
}

variable "github_config_url" {
  description = "GitHub repo/org URL for ARC runners"
  type        = string
  default     = "https://github.com/NousResearch/hermes-agent"
}

###############################################################################
# Provider
###############################################################################

provider "google" {
  project = var.project_id
  region  = var.region
}

###############################################################################
# Enable APIs
###############################################################################

resource "google_project_service" "container" {
  service            = "container.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service" "compute" {
  service            = "compute.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service" "iam" {
  service            = "iam.googleapis.com"
  disable_on_destroy = false
}

###############################################################################
# GKE Cluster
###############################################################################

resource "google_container_cluster" "gha_runners" {
  name           = var.cluster_name
  location       = var.region
  node_locations = [var.zone]

  # Default node pool — runs the ARC controller, cert-manager, cache server
  # We create it as a separate node pool below so the default pool can be
  # removed (GKE creates one automatically, we set remove_default_node_pool).
  remove_default_node_pool = true
  initial_node_count       = 1

  enable_shielded_nodes = true

  # Required for the gke-gcloud-auth-plugin
  release_channel {
    channel = "REGULAR"
  }

  depends_on = [
    google_project_service.container,
    google_project_service.compute,
  ]

  lifecycle {
    ignore_changes = [
      initial_node_count,
      remove_default_node_pool,
    ]
  }
}

###############################################################################
# Node Pool: default-pool (controller + system services)
###############################################################################

resource "google_container_node_pool" "default_pool" {
  name           = "default-pool"
  cluster        = google_container_cluster.gha_runners.name
  location       = var.region
  node_locations = [var.zone]

  initial_node_count = 1

  autoscaling {
    min_node_count  = 1
    max_node_count  = 3
    location_policy = "BALANCED"
  }

  node_config {
    machine_type = "e2-standard-2"
    disk_size_gb = 50

    oauth_scopes = [
      "https://www.googleapis.com/auth/devstorage.read_only",
      "https://www.googleapis.com/auth/logging.write",
      "https://www.googleapis.com/auth/monitoring",
      "https://www.googleapis.com/auth/service.management.readonly",
      "https://www.googleapis.com/auth/servicecontrol",
      "https://www.googleapis.com/auth/trace.append",
    ]
  }
}

###############################################################################
# Node Pool: spot-runners (ephemeral runner pods, scales to zero)
###############################################################################

resource "google_container_node_pool" "spot_runners" {
  name           = "spot-runners"
  cluster        = google_container_cluster.gha_runners.name
  location       = var.region
  node_locations = [var.zone]

  initial_node_count = 0

  autoscaling {
    min_node_count  = 0
    max_node_count  = 20
    location_policy = "ANY"
  }

  node_config {
    machine_type = "e2-standard-4"
    disk_size_gb = 100

    spot = true

    # Label used by ARC runner pods' nodeSelector
    labels = {
      dedicated = "gha-runners"
    }

    oauth_scopes = [
      "https://www.googleapis.com/auth/devstorage.read_only",
      "https://www.googleapis.com/auth/logging.write",
      "https://www.googleapis.com/auth/monitoring",
      "https://www.googleapis.com/auth/service.management.readonly",
      "https://www.googleapis.com/auth/servicecontrol",
      "https://www.googleapis.com/auth/trace.append",
    ]
  }
}

###############################################################################
# Node Pool: spot-runners-arm64 (ARM64 runner pods, scales to zero)
###############################################################################

# ARM workloads cannot run on the existing e2-standard (amd64) pool. Keep a
# separate T2A spot pool so only jobs explicitly routed to the ARM ARC scale
# set cause ARM capacity to boot.
resource "google_container_node_pool" "spot_runners_arm64" {
  name           = "spot-runners-arm64"
  cluster        = google_container_cluster.gha_runners.name
  location       = var.region
  node_locations = [var.zone]

  initial_node_count = 0

  autoscaling {
    min_node_count  = 0
    max_node_count  = 6
    location_policy = "ANY"
  }

  node_config {
    machine_type = "t2a-standard-4"
    disk_size_gb = 100

    spot = true

    # Select this pool only from the dedicated ARM ARC scale set.
    labels = {
      dedicated = "gha-runners-arm64"
    }

    oauth_scopes = [
      "https://www.googleapis.com/auth/devstorage.read_only",
      "https://www.googleapis.com/auth/logging.write",
      "https://www.googleapis.com/auth/monitoring",
      "https://www.googleapis.com/auth/service.management.readonly",
      "https://www.googleapis.com/auth/servicecontrol",
      "https://www.googleapis.com/auth/trace.append",
    ]
  }
}

###############################################################################
# GCS Bucket for cache server
###############################################################################

resource "google_storage_bucket" "cache" {
  # This is the name created by the initial deployment. Keep it stable: the
  # cache bucket contains reusable CI artifacts and must never be replaced.
  name          = "hermes-agent-gha-cache"
  location      = var.region
  force_destroy = false

  uniform_bucket_level_access = true
}

###############################################################################
# IAM: Service Account for cache server
###############################################################################

resource "google_service_account" "cache_server" {
  account_id   = "gha-cache-server"
  display_name = "GHA Cache Server"
  project      = var.project_id
}

# Object admin on the cache bucket
resource "google_storage_bucket_iam_member" "cache_object_admin" {
  bucket = google_storage_bucket.cache.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.cache_server.email}"
}

# Bucket reader for startup bucket check (storage.buckets.get)
resource "google_storage_bucket_iam_member" "cache_bucket_reader" {
  bucket = google_storage_bucket.cache.name
  role   = "roles/storage.legacyBucketReader"
  member = "serviceAccount:${google_service_account.cache_server.email}"
}

###############################################################################
# Outputs
###############################################################################

output "cluster_name" {
  value = google_container_cluster.gha_runners.name
}

output "cluster_region" {
  value = var.region
}

output "cache_bucket" {
  value = google_storage_bucket.cache.name
}

output "cache_service_account_email" {
  value = google_service_account.cache_server.email
}
