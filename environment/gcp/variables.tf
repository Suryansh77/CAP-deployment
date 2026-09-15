variable "project_id" {
  type = string
}

variable "region" {
  type    = string
  default = "asia-south1"
}

variable "zone" {
  type    = string
  default = "asia-south1-a"
}

variable "cluster_name" {
  type    = string
  default = "cap-gke-tf"
}

variable "repository_name" {
  type    = string
  default = "cap"
}

variable "machine_type" {
  type    = string
  default = "e2-standard-2"
}
