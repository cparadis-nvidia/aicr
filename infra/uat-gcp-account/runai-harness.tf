# Copyright (c) 2026, NVIDIA CORPORATION & AFFILIATES.  All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# Run:ai control-plane harness credential for the platform=runai UAT cells
# (NVIDIA/aicr#3302, "Validation contract"). The lane authenticates to a
# long-lived Run:ai control plane as a service account; uat-gcp.yaml reads this
# secret through the github-actions Workload Identity it already has and
# publishes it to the phase steps masked (tests/uat/lib/runai-harness.sh,
# runai_credential_export). No GitHub secret is involved.
#
# Only the container is managed here. The value, a JSON document
#   {"url": "https://<control plane>", "clientId": "...", "clientSecret": "...",
#    "caCert": "<PEM, optional>"}
# is added out of band by whoever operates the control plane
# (`gcloud secrets versions add aicr-uat-runai-harness --data-file=...`), so no
# credential ever passes through Terraform state or a pull request.
resource "google_secret_manager_secret" "runai_harness" {
  secret_id = "aicr-uat-runai-harness"
  project   = var.project_id

  replication {
    auto {}
  }

  labels = {
    environment = "ci"
    managed-by  = "terraform"
    purpose     = "uat-runai-harness"
  }

  depends_on = [google_project_service.default]
}

# gcp-shared already grants roles/secretmanager.secretAccessor project-wide
# (see iam.tf); this binding pins the lane's access to this one secret so the
# grant survives a narrowing of that project-level role.
resource "google_secret_manager_secret_iam_member" "runai_harness_accessor" {
  project   = var.project_id
  secret_id = google_secret_manager_secret.runai_harness.secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${data.google_service_account.github_actions.email}"
}
