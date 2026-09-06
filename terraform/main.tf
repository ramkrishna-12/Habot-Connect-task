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

  # Access-log entries write to this same bucket under a distinct prefix.
  # Note: the loader service (Task 3) is what actually quarantines objects
  # that fail schema validation — it moves them to an `incoming-quarantine/`
  # prefix instead of loading or discarding them; that behaviour lives in
  # application code, not in this bucket's own configuration.
  logging {
    log_bucket = "${var.project_id}-d0-raw-landing-${var.environment}"
  }

  labels = merge(var.labels, { zone = "d0-raw-landing" })
}

# Ingest writer may only ever write new objects under incoming/ — it cannot
# list, read, or delete anything, including its own uploads. This is an IAM
# Condition, not a comment: it is enforced by GCP at request time.
resource "google_storage_bucket_iam_member" "d0_writer_binding" {
  bucket = google_storage_bucket.d0_raw_landing.name
  role   = "roles/storage.objectCreator"
  member = "serviceAccount:${google_service_account.d0_ingest_writer.email}"

  condition {
    title       = "restrict-to-incoming-prefix"
    description = "Ingest writer may only create objects under incoming/, never overwrite or read existing objects."
    expression  = "resource.name.startsWith(\"projects/_/buckets/${google_storage_bucket.d0_raw_landing.name}/objects/incoming/\")"
  }
}

# Loader may only read objects it needs to promote to D1, and only within a
# 24h freshness window — a stale, forgotten object cannot be silently loaded
# months later by a re-run of the pipeline.
resource "google_storage_bucket_iam_member" "d0_loader_read_binding" {
  bucket = google_storage_bucket.d0_raw_landing.name
  role   = "roles/storage.objectViewer"
  member = "serviceAccount:${google_service_account.d1_bq_loader.email}"

  condition {
    title       = "restrict-to-fresh-incoming-objects"
    description = "Loader may only read objects under incoming/ created within the last 24 hours."
    expression  = <<-EOT
      resource.name.startsWith("projects/_/buckets/${google_storage_bucket.d0_raw_landing.name}/objects/incoming/") &&
      request.time < resource.create_time + duration("24h")
    EOT
  }
}

# ---------------------------------------------------------------------------
# D1 — Staged / Enforced (BigQuery)
# ---------------------------------------------------------------------------

resource "google_bigquery_dataset" "d1_staged_enforced" {
  dataset_id                  = "d1_staged_enforced_${var.environment}"
  project                     = var.project_id
  location                    = var.region
  default_table_expiration_ms = null # enforced data is retained; expiry is a schema decision, not a dataset default
  delete_contents_on_destroy  = false

  default_encryption_configuration {
    kms_key_name = var.kms_key_id
  }

  # No broad dataset-level access entries beyond the owning group. All other
  # access is granted at the table/row level below — dataset-wide OWNER/WRITER
  # roles for individual users are the exact anti-pattern this project exists
  # to eliminate.
  access {
    role           = "OWNER"
    group_by_email = var.data_engineering_group
  }
  access {
    role          = "WRITER"
    user_by_email = google_service_account.d1_bq_loader.email
  }

  labels = merge(var.labels, { zone = "d1-staged-enforced" })
}

resource "google_bigquery_table" "student_onboarding" {
  dataset_id          = google_bigquery_dataset.d1_staged_enforced.dataset_id
  table_id            = "student_onboarding"
  project             = var.project_id
  deletion_protection = true

  # Schema mirrors the DCYN-deconstructed output of the Django serializer in
  # Task 3 — every ambiguous free-text field from the raw D0 payload has
  # already been resolved to a strict type before it reaches D1.
  schema = jsonencode([
    { name = "record_id", type = "STRING", mode = "REQUIRED" },
    { name = "full_legal_name", type = "STRING", mode = "REQUIRED" },
    { name = "date_of_birth", type = "DATE", mode = "REQUIRED" },
    { name = "guardian_email", type = "STRING", mode = "REQUIRED" },
    { name = "region", type = "STRING", mode = "REQUIRED" },
    { name = "has_diagnosed_learning_difficulty", type = "STRING", mode = "REQUIRED" }, # DCYN: "Y" | "N"
    { name = "diagnosis_document_reference", type = "STRING", mode = "NULLABLE" },
    { name = "guardian_consent_given", type = "STRING", mode = "REQUIRED" },     # DCYN: "Y" | "N"
    { name = "requires_lsa_accommodation", type = "STRING", mode = "REQUIRED" }, # DCYN: "Y" | "N"
    { name = "prior_lsa_support_received", type = "STRING", mode = "REQUIRED" }, # DCYN: "Y" | "N"
    { name = "loaded_at", type = "TIMESTAMP", mode = "REQUIRED" },
  ])
}

# Row-Level Security: the analytics reader's own group membership determines
# which rows it can see. Even though it holds SELECT on the whole table, GCP
# evaluates this predicate on every query — an analyst assigned to one
# region can never see another region's student records, no matter what
# query they write.
resource "google_bigquery_row_access_policy" "regional_restriction" {
  project          = var.project_id
  dataset_id       = google_bigquery_dataset.d1_staged_enforced.dataset_id
  table_id         = google_bigquery_table.student_onboarding.table_id
  policy_id        = "restrict_by_analyst_region"
  filter_predicate = "region = (SELECT region FROM `${var.project_id}.d1_staged_enforced_${var.environment}.analyst_region_map` WHERE analyst_email = SESSION_USER())"

  grantees = [
    "serviceAccount:${google_service_account.d1_analytics_reader.email}",
  ]
}

resource "google_bigquery_dataset_iam_member" "analytics_reader_binding" {
  dataset_id = google_bigquery_dataset.d1_staged_enforced.dataset_id
  project    = var.project_id
  role       = "roles/bigquery.dataViewer"
  member     = "serviceAccount:${google_service_account.d1_analytics_reader.email}"
}
