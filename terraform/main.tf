# Copyright 2022 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# Definition of local variables
locals {
  base_apis = [
    "container.googleapis.com",
    "monitoring.googleapis.com",
    "cloudtrace.googleapis.com",
    "cloudprofiler.googleapis.com"
  ]
  memorystore_apis  = ["redis.googleapis.com"]
  cluster_name      = google_container_cluster.my_cluster.name
  target_namespaces = length(var.environment_namespaces) > 0 ? var.environment_namespaces : [var.namespace]
}

data "google_project" "current" {
  project_id = var.gcp_project_id
}

# Enable Google Cloud APIs
module "enable_google_apis" {
  source  = "terraform-google-modules/project-factory/google//modules/project_services"
  version = "~> 18.0"

  project_id                  = var.gcp_project_id
  disable_services_on_destroy = false

  # activate_apis is the set of base_apis and the APIs required by user-configured deployment options
  activate_apis = concat(local.base_apis, var.memorystore ? local.memorystore_apis : [])
}

# Create GKE cluster
resource "google_container_cluster" "my_cluster" {

  name     = var.name
  location = var.region

  remove_default_node_pool = true
  initial_node_count       = 1

  # Enable VPC-native mode.
  ip_allocation_policy {
  }

  deletion_protection = false

  depends_on = [
    module.enable_google_apis
  ]
}

resource "google_project_iam_member" "default_node_sa_role" {
  project = var.gcp_project_id
  role    = "roles/container.defaultNodeServiceAccount"
  member  = "serviceAccount:${data.google_project.current.number}-compute@developer.gserviceaccount.com"
}

resource "google_container_node_pool" "primary_nodes" {
  name     = "${var.name}-node-pool"
  location = google_container_cluster.my_cluster.location
  cluster  = google_container_cluster.my_cluster.name

  node_count = var.node_count

  node_config {
    machine_type = var.node_machine_type
    oauth_scopes = ["https://www.googleapis.com/auth/cloud-platform"]
  }

  management {
    auto_repair  = true
    auto_upgrade = true
  }
}

# Get credentials for cluster
module "gcloud" {
  source  = "terraform-google-modules/gcloud/google"
  version = "~> 4.0"

  platform              = "linux"
  additional_components = ["kubectl", "beta"]

  create_cmd_entrypoint = "gcloud"
  # Module does not support explicit dependency
  # Enforce implicit dependency through use of local variable
  create_cmd_body = "container clusters get-credentials ${local.cluster_name} --location=${var.region} --project=${var.gcp_project_id}"
}

# Ensure target namespaces exist
resource "null_resource" "create_namespaces" {
  for_each = toset(local.target_namespaces)

  triggers = {
    cluster_id = google_container_cluster.my_cluster.id
    namespace  = each.value
  }

  provisioner "local-exec" {
    interpreter = ["bash", "-exc"]
    command     = "kubectl create namespace ${each.value} --dry-run=client -o yaml | kubectl apply -f -"
  }

  depends_on = [
    module.gcloud,
    google_container_node_pool.primary_nodes
  ]
}

# Apply YAML kubernetes-manifest configurations
resource "null_resource" "apply_deployment" {
  for_each = toset(local.target_namespaces)

  triggers = {
    cluster_id = google_container_cluster.my_cluster.id
    namespace  = each.value
  }

  provisioner "local-exec" {
    interpreter = ["bash", "-exc"]
    command     = "kubectl apply -k ${var.filepath_manifest} -n ${each.value}"
  }

  depends_on = [
    null_resource.create_namespaces
  ]
}

# Wait condition for all Pods to be ready before finishing
resource "null_resource" "wait_conditions" {
  for_each = toset(local.target_namespaces)

  triggers = {
    cluster_id           = google_container_cluster.my_cluster.id
    apply_deployment_id  = null_resource.apply_deployment[each.key].id
    deployment_namespace = each.value
  }

  provisioner "local-exec" {
    interpreter = ["bash", "-exc"]
    command     = <<-EOT
    for deployment in $(kubectl get deployment -n ${each.value} -o name | grep -v "deployment.apps/loadgenerator"); do
      kubectl rollout status -n ${each.value} "$deployment" --timeout=900s
    done
    EOT
  }

  depends_on = [
    null_resource.apply_deployment
  ]
}
