/**
 * Task 1 — Terraform Secure Staging Provisioning
 * -----------------------------------------------
 * Provisions:
 *   D0  Raw Landing  -> google_storage_bucket.d0_raw_landing
 *   D1  Staged/Enforced -> google_bigquery_dataset.d1_staged_enforced
 *
 * Design principles enforced here (mapped to the "Golden Rules" the
 * assignment describes as Poka-Yoke / mistake-proofing, not optional style):
 *   1. Nothing is publicly reachable — public access prevention is
 *      "enforced", not merely "inherited", at the bucket level.
 *   2. Every identity binding is scoped to exactly one role and, where
 *      GCP supports it, an IAM Condition — no broad Editor/Owner grants.
 *   3. Encryption at rest uses a customer-managed key (CMEK), not the
 *      Google-default key, because student data (including disability
 *      / learning-difficulty status) is sensitive.
 *   4. Row-Level Security on the enforced BigQuery table means even an
 *      identity with SELECT on the table cannot see rows outside its
 *      declared scope — access control lives in the data plane, not
 *      just the IAM plane.
 */

terraform {
  required_version = ">= 1.7.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
  }

  # Remote state is mandatory for this pipeline — local state for a
  # bucket/dataset pair that handles student PII is itself a Poka-Yoke
  # violation (no audit trail, no locking, easy to leak in a laptop backup).
  backend "gcs" {
    bucket = "habotconnect-tfstate-staging" # pre-created out of band, least-privilege access only
    prefix = "student-onboarding-pipeline"
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

data "google_project" "current" {}

# ---------------------------------------------------------------------------
# Service accounts — one identity per stage of the pipeline. No identity is
# reused across stages, so a compromised ingest credential cannot read D1,
# and the analytics reader can never write to either zone.
# ---------------------------------------------------------------------------

resource "google_service_account" "d0_ingest_writer" {
  account_id   = var.pipeline_ingest_sa_id
  display_name = "D0 raw-landing writer (ingest only, no read-back, no BigQuery access)"
}

resource "google_service_account" "d1_bq_loader" {
  account_id   = var.pipeline_loader_sa_id
  display_name = "D0 -> D1 loader (read D0, write D1, nothing else)"
}

resource "google_service_account" "d1_analytics_reader" {
  account_id   = var.analytics_reader_sa_id
  display_name = "Downstream analytics/BI reader, subject to Row-Level Security on D1"
}

# ---------------------------------------------------------------------------
# D0 — Raw Landing (Google Cloud Storage)
# ---------------------------------------------------------------------------

resource "google_storage_bucket" "d0_raw_landing" {
  name     = "${var.project_id}-d0-raw-landing-${var.environment}"
  location = var.region
  project  = var.project_id

  uniform_bucket_level_access = true # disallows legacy per-object ACLs entirely
  public_access_prevention    = "enforced"
  force_destroy               = false

  versioning {
    enabled = true # an overwritten raw payload must still be recoverable for audit
  }

  encryption {
    default_kms_key_name = var.kms_key_id
  }

  lifecycle_rule {
    condition {
      age = 30 # raw payloads are transient by design once staged into D1
    }
    action {
      type          = "SetStorageClass"
      storage_class = "NEARLINE"
    }
  }
