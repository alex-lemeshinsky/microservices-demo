# DevOps Test Task - GKE Deployment (Staging + Production)

## 1. Context

This document describes the end-to-end flow used to deploy the Online Boutique microservices app to Google Kubernetes Engine (GKE) for the test task.

- Cloud provider: GCP
- Project ID: `hackathon-test-task-488518`
- Repository: `microservices-demo`
- IaC tool: Terraform
- Environments: `staging`, `production` (separate Kubernetes namespaces)

## 2. High-Level Architecture

- 1 GKE cluster: `online-boutique`
- Location: `us-central1-a` (zonal)
- Cluster type: Standard (not Autopilot)
- Node pool: `online-boutique-node-pool`
  - Machine type: `e2-standard-4`
  - Node count: `1`
- Namespaces:
  - `staging`
  - `production`
- Deployment source: `kustomize/` manifests applied per namespace
- Public access:
  - `frontend-external` LoadBalancer service in each namespace

## 3. Terraform Changes Made

Main files updated:

- `terraform/main.tf`
- `terraform/variables.tf`
- `terraform/terraform.tfvars`
- `terraform/output.tf`
- `terraform/memorystore.tf` (format-only alignment from `terraform fmt`)

Key implementation points:

1. Added support for multiple namespaces via:
   - `environment_namespaces` variable
   - looped `null_resource` for namespace creation, deployment apply, readiness checks
2. Replaced Autopilot cluster with Standard GKE:
   - `google_container_cluster` with `remove_default_node_pool = true`
   - explicit `google_container_node_pool`
3. Improved readiness logic:
   - rollout-based checks per Deployment
   - excluded `loadgenerator` from rollout gating
4. Added `triggers` on `null_resource` blocks so re-deploy is forced after cluster replacement.

## 4. Deployment Flow (Step-by-Step)

### 4.1 Prerequisites

1. Logged in to GCP account with sufficient permissions.
2. Billing enabled for project `hackathon-test-task-488518`.
3. Terraform installed.

### 4.2 Configure Terraform

In `terraform/terraform.tfvars`:

- `gcp_project_id = "hackathon-test-task-488518"`
- `region = "us-central1-a"`
- `environment_namespaces = ["staging", "production"]`
- `node_machine_type = "e2-standard-4"`
- `node_count = 1`

### 4.3 Apply Infrastructure and Deploy Workloads

From `terraform/` directory:

```bash
terraform init
terraform plan
terraform apply -auto-approve
```

Terraform flow:

1. Enable required GCP APIs.
2. Create GKE cluster + node pool.
3. Fetch cluster credentials.
4. Create namespaces (`staging`, `production`).
5. Apply kustomize manifests to both namespaces.
6. Wait for deployment rollouts.

### 4.4 Validate Deployment

Validation commands:

```bash
kubectl get ns
kubectl get deploy -n staging
kubectl get deploy -n production
kubectl get svc -n staging frontend-external
kubectl get svc -n production frontend-external
```

HTTP checks:

```bash
curl -I http://<staging-frontend-external-ip>
curl -I http://<production-frontend-external-ip>
```

At deployment time, both frontends returned HTTP `200`.

## 5. Issues Encountered and Fixes

### Issue 1: Old metrics API check failed

- Symptom:
  - `apiservice/v1beta1.metrics.k8s.io` not found.
- Root cause:
  - Legacy API version check incompatible with current cluster behavior.
- Fix:
  - Removed APIService wait and switched to deployment rollout-based readiness checks.

### Issue 2: Autopilot scheduling instability and failed scale-up

- Symptom:
  - Many pods stuck in `Pending`.
  - Events showed `FailedScaleUp`, `Insufficient cpu`, and quota-related scale-up failures.
- Root cause:
  - Autopilot scale decisions + environment quota/capacity conditions caused blocked scheduling.
- Fix:
  - Migrated to Standard zonal cluster with explicit fixed node pool (`e2-standard-4`, 1 node).

### Issue 3: Cluster replacement blocked by deletion protection

- Symptom:
  - Terraform could not destroy existing cluster due to `deletion_protection = true`.
- Root cause:
  - Existing state/resources had protection enabled.
- Fix:
  - Set `deletion_protection = false` in cluster resource and corrected Terraform state to allow replacement.

### Issue 4: `null_resource` steps did not re-run after cluster replacement

- Symptom:
  - New cluster created, but apply/deploy steps were not forced.
- Root cause:
  - `null_resource` had no `triggers` tied to cluster identity.
- Fix:
  - Added `triggers` using cluster ID and dependency IDs to force namespace/app re-apply when cluster changes.

### Issue 5: `loadgenerator` affects generic pod readiness

- Symptom:
  - Full `pods --all` waits were unreliable for environment readiness.
- Root cause:
  - `loadgenerator` behavior is not a strict readiness signal for platform health.
- Fix:
  - Readiness gate now checks rollout status of business deployments and excludes `loadgenerator`.

## 6. Terraform Destroy (Cleanup)

To remove created infrastructure:

```bash
cd terraform
terraform destroy -auto-approve
```

This satisfies the task requirement to remove provisioned cloud resources after completion.

## 7. Evidence and Deliverables Checklist (per PDF)

### Completed in this repository

- [x] Terraform deploys infrastructure
- [x] Terraform can destroy infrastructure
- [x] `staging` + `production` namespaces deployed
- [x] Frontend exposed for both environments
- [x] High-level architecture description included
- [x] Issues and solutions documented

### Remaining for full final submission package

- [ ] CI/CD for at least 2 microservices (build + push + deploy to staging/prod)
- [ ] 2-3 useful monitoring/observability dashboards (reliability + scalability)
- [ ] Screenshots:
  - [ ] deployed system in cloud
  - [ ] CI/CD setup
  - [ ] dashboards
- [ ] Recorded end-to-end demo video with voice explanation

