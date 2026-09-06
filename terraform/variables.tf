variable "project_id" {
  description = "GCP project ID for the staging environment."
  type        = string
}

variable "region" {
  description = "Primary region for regional resources."
  type        = string
  default     = "me-central1" # nearest GCP region to HabotConnect's MENA user base; override per environment
}

variable "environment" {
  description = "Deployment environment name. Used in resource naming and labels."
  type        = string
  default     = "staging"

  validation {
    condition     = contains(["staging", "production"], var.environment)
    error_message = "environment must be exactly one of: staging, production. No ad-hoc environment names."
  }
}

variable "kms_key_id" {
  description = "Fully-qualified self link of the Cloud KMS CryptoKey used to encrypt D0/D1 data at rest. Required — this pipeline does not support Google-managed-only encryption for staged student data."
  type        = string
}

variable "data_engineering_group" {
  description = "Google Group email that holds day-to-day operator access (least-privilege, group-based — never individual user bindings)."
  type        = string
}

variable "pipeline_ingest_sa_id" {
  description = "Account ID (not full email) for the service account allowed to write into the D0 raw landing bucket."
  type        = string
  default     = "d0-ingest-writer"
}

variable "pipeline_loader_sa_id" {
  description = "Account ID for the service account allowed to load D0 -> D1 (GCS -> BigQuery) and nothing else."
  type        = string
  default     = "d1-bq-loader"
}

variable "analytics_reader_sa_id" {
  description = "Account ID for the service account used by downstream analytics/BI tools. Row-Level Security is enforced against this identity."
  type        = string
  default     = "d1-analytics-reader"
}

variable "labels" {
  description = "Common resource labels for cost allocation and audit."
  type        = map(string)
  default = {
    system = "student-onboarding-pipeline"
    owner  = "cloud-devops"
  }
}
