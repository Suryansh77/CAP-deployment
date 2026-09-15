resource "google_project_service" "container" {
  project            = var.project_id
  service            = "container.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service" "artifactregistry" {
  project            = var.project_id
  service            = "artifactregistry.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service" "compute" {
  project            = var.project_id
  service            = "compute.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service" "iam" {
  project            = var.project_id
  service            = "iam.googleapis.com"
  disable_on_destroy = false
}

resource "google_compute_network" "cap" {
  name                    = "cap-gke-vpc"
  auto_create_subnetworks = false
}

resource "google_compute_subnetwork" "cap" {
  name                     = "cap-gke-subnet"
  region                   = var.region
  network                  = google_compute_network.cap.id
  ip_cidr_range            = "10.20.0.0/20"
  private_ip_google_access = true

  secondary_ip_range {
    range_name    = "gke-pods"
    ip_cidr_range = "10.24.0.0/14"
  }

  secondary_ip_range {
    range_name    = "gke-services"
    ip_cidr_range = "10.28.0.0/20"
  }
}

resource "google_artifact_registry_repository" "cap" {
  location      = var.region
  repository_id = var.repository_name
  description   = "CAP private container registry"
  format        = "DOCKER"

  depends_on = [google_project_service.artifactregistry]
}

resource "google_service_account" "gke_nodes" {
  account_id   = "cap-gke-nodes"
  display_name = "CAP GKE node service account"
}

resource "google_project_iam_member" "gke_node_service_account" {
  project = var.project_id
  role    = "roles/container.defaultNodeServiceAccount"
  member  = "serviceAccount:${google_service_account.gke_nodes.email}"
}

resource "google_artifact_registry_repository_iam_member" "gke_node_reader" {
  project    = var.project_id
  location   = var.region
  repository = google_artifact_registry_repository.cap.repository_id
  role       = "roles/artifactregistry.reader"
  member     = "serviceAccount:${google_service_account.gke_nodes.email}"
}

resource "google_container_cluster" "cap" {
  name     = var.cluster_name
  location = var.zone

  network    = google_compute_network.cap.id
  subnetwork = google_compute_subnetwork.cap.id

  remove_default_node_pool = true
  initial_node_count       = 1
  deletion_protection      = false

  networking_mode   = "VPC_NATIVE"
  datapath_provider = "ADVANCED_DATAPATH"

  ip_allocation_policy {
    cluster_secondary_range_name  = "gke-pods"
    services_secondary_range_name = "gke-services"
  }

  workload_identity_config {
    workload_pool = "${var.project_id}.svc.id.goog"
  }

  release_channel {
    channel = "REGULAR"
  }

  depends_on = [
    google_project_service.container,
    google_compute_subnetwork.cap,
    google_project_iam_member.gke_node_service_account
  ]
}

resource "google_container_node_pool" "cap" {
  name       = "cap-gke-pool"
  location   = var.zone
  cluster    = google_container_cluster.cap.name
  node_count = 1

  node_config {
    machine_type    = var.machine_type
    service_account = google_service_account.gke_nodes.email

    oauth_scopes = [
      "https://www.googleapis.com/auth/cloud-platform"
    ]

    shielded_instance_config {
      enable_secure_boot          = true
      enable_integrity_monitoring = true
    }
  }

  management {
    auto_repair  = true
    auto_upgrade = true
  }

  depends_on = [
    google_artifact_registry_repository_iam_member.gke_node_reader
  ]
}
