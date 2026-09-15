output "cluster_name" {
  value = google_container_cluster.cap.name
}

output "cluster_zone" {
  value = google_container_cluster.cap.location
}

output "registry_uri" {
  value = "${var.region}-docker.pkg.dev/${var.project_id}/${var.repository_name}"
}

output "node_service_account" {
  value = google_service_account.gke_nodes.email
}

output "vpc_name" {
  value = google_compute_network.cap.name
}
