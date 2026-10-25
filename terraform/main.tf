terraform {
  required_version = ">= 1.5"
  required_providers {
    google  = { source = "hashicorp/google", version = "~> 6.0" }
    archive = { source = "hashicorp/archive", version = "~> 2.4" }
    time    = { source = "hashicorp/time", version = "~> 0.11" }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
  zone    = var.zone
}

data "google_project" "this" { project_id = var.project_id }

locals {
  suffix = substr(md5(var.project_id), 0, 6)
  p      = "${var.name_prefix}-${local.suffix}"
}

# ---------- APIs ----------
resource "google_project_service" "apis" {
  for_each = toset([
    "compute.googleapis.com", "logging.googleapis.com", "monitoring.googleapis.com",
    "aiplatform.googleapis.com", "cloudfunctions.googleapis.com", "run.googleapis.com",
    "cloudbuild.googleapis.com", "artifactregistry.googleapis.com", "storage.googleapis.com",
  ])
  service            = each.key
  disable_on_destroy = false
}

# ---------- Buckets ----------
resource "google_storage_bucket" "web" {
  name                        = "${local.p}-web"
  location                    = var.region
  uniform_bucket_level_access = true
  force_destroy               = true
  website { main_page_suffix = "index.html" }
  cors {
    origin = ["*"]
    method = ["GET"]
  }
  depends_on = [google_project_service.apis]
}

# DEMO: public website. If an org policy blocks allUsers, front the bucket with a load balancer / Firebase Hosting.
resource "google_storage_bucket_iam_member" "web_public" {
  bucket = google_storage_bucket.web.name
  role   = "roles/storage.objectViewer"
  member = "allUsers"
}

resource "google_storage_bucket" "knowledge" {
  name                        = "${local.p}-knowledge"
  location                    = var.region
  uniform_bucket_level_access = true
  force_destroy               = true
  depends_on                  = [google_project_service.apis]
}

resource "google_storage_bucket" "build" {
  name                        = "${local.p}-build"
  location                    = var.region
  uniform_bucket_level_access = true
  force_destroy               = true
  depends_on                  = [google_project_service.apis]
}

resource "google_storage_bucket_object" "kb" {
  for_each = fileset("${path.module}/../knowledge", "**/*.md")
  name     = each.value
  bucket   = google_storage_bucket.knowledge.name
  source   = "${path.module}/../knowledge/${each.value}"
}

resource "google_storage_bucket_object" "app_py" {
  name   = "app/app.py"
  bucket = google_storage_bucket.build.name
  source = "${path.module}/../sample-app/app.py"
}

# ---------- Service accounts ----------
resource "google_service_account" "vm" {
  account_id   = "${var.name_prefix}-vm"
  display_name = "Sample app VM"
}

resource "google_service_account" "fn" {
  account_id   = "${var.name_prefix}-fn"
  display_name = "AI ops function"
}

resource "google_project_iam_member" "vm_roles" {
  for_each = toset(["roles/logging.logWriter", "roles/monitoring.metricWriter"])
  project  = var.project_id
  role     = each.key
  member   = "serviceAccount:${google_service_account.vm.email}"
}

resource "google_project_iam_member" "fn_roles" {
  for_each = toset(["roles/logging.viewer", "roles/monitoring.viewer", "roles/aiplatform.user"])
  project  = var.project_id
  role     = each.key
  member   = "serviceAccount:${google_service_account.fn.email}"
}

resource "google_storage_bucket_iam_member" "vm_reads_build" {
  bucket = google_storage_bucket.build.name
  role   = "roles/storage.objectViewer"
  member = "serviceAccount:${google_service_account.vm.email}"
}

resource "google_storage_bucket_iam_member" "fn_reads_kb" {
  bucket = google_storage_bucket.knowledge.name
  role   = "roles/storage.objectViewer"
  member = "serviceAccount:${google_service_account.fn.email}"
}

# Grant required build permissions to the default compute service account
resource "google_project_iam_member" "default_compute_build_roles" {
  for_each = toset([
    "roles/cloudbuild.builds.builder",
    "roles/logging.logWriter",
    "roles/artifactregistry.writer",
    "roles/storage.objectViewer",
  ])
  project = var.project_id
  role    = each.key
  member  = "serviceAccount:${data.google_project.this.number}-compute@developer.gserviceaccount.com"
}

# Also grant build roles to Cloud Build service account
resource "google_project_iam_member" "cloudbuild_sa_roles" {
  for_each = toset([
    "roles/cloudbuild.builds.builder",
    "roles/logging.logWriter",
    "roles/artifactregistry.writer",
    "roles/storage.objectViewer",
  ])
  project = var.project_id
  role    = each.key
  member  = "serviceAccount:${data.google_project.this.number}@cloudbuild.gserviceaccount.com"
}

# Wait for GCP IAM policy changes to propagate across Cloud Build & Artifact Registry
resource "time_sleep" "wait_for_iam" {
  depends_on = [
    google_project_service.apis,
    google_project_iam_member.default_compute_build_roles,
    google_project_iam_member.cloudbuild_sa_roles,
    google_project_iam_member.fn_roles,
  ]
  create_duration = "45s"
}

# ---------- Sample app VM ----------
resource "google_compute_firewall" "app" {
  name          = "${local.p}-allow-app"
  network       = "default"
  source_ranges = [var.allowed_cidr]
  target_tags   = ["sample-app"]
  allow {
    protocol = "tcp"
    ports    = ["8080"]
  }
  depends_on = [google_project_service.apis]
}

resource "google_compute_instance" "app" {
  name         = "${var.name_prefix}-sample-app"
  machine_type = "e2-small"
  tags         = ["sample-app"]

  boot_disk {
    initialize_params { image = "debian-cloud/debian-12" }
  }
  network_interface {
    network = "default"
    access_config {} # ephemeral public IP
  }
  service_account {
    email  = google_service_account.vm.email
    scopes = ["cloud-platform"]
  }
  metadata_startup_script = templatefile("${path.module}/startup.sh.tpl", {
    build_bucket = google_storage_bucket.build.name
  })
  depends_on = [google_storage_bucket_object.app_py, google_storage_bucket_iam_member.vm_reads_build]
}

# ---------- Cloud Run function (2nd gen) ----------
data "archive_file" "fn" {
  type        = "zip"
  source_dir  = "${path.module}/../function"
  output_path = "${path.module}/build/function.zip"
}

resource "google_storage_bucket_object" "fn_zip" {
  name   = "function-${data.archive_file.fn.output_md5}.zip"
  bucket = google_storage_bucket.build.name
  source = data.archive_file.fn.output_path
}

resource "google_cloudfunctions2_function" "ask" {
  name     = "${var.name_prefix}-ask"
  location = var.region

  build_config {
    runtime     = "python312"
    entry_point = "ask"
    source {
      storage_source {
        bucket = google_storage_bucket.build.name
        object = google_storage_bucket_object.fn_zip.name
      }
    }
  }

  service_config {
    available_memory      = "512Mi"
    timeout_seconds       = 120
    max_instance_count    = 3
    service_account_email = google_service_account.fn.email
    environment_variables = {
      PROJECT_ID       = var.project_id
      REGION           = var.region
      VERTEX_LOCATION  = var.vertex_location
      GEMINI_MODEL     = var.gemini_model
      KNOWLEDGE_BUCKET = google_storage_bucket.knowledge.name
      APP_LOG_NAME     = "sample_app"
    }
  }

  depends_on = [
    google_project_service.apis,
    google_project_iam_member.fn_roles,
    google_project_iam_member.default_compute_build_roles,
    google_project_iam_member.cloudbuild_sa_roles,
    time_sleep.wait_for_iam
  ]
}

resource "google_cloud_run_service_iam_member" "public_invoker" {
  count    = var.allow_unauthenticated ? 1 : 0
  location = var.region
  service  = google_cloudfunctions2_function.ask.service_config[0].service
  role     = "roles/run.invoker"
  member   = "allUsers"
}

# ---------- Web UI (config.js is generated with the function URL) ----------
resource "google_storage_bucket_object" "index" {
  name         = "index.html"
  bucket       = google_storage_bucket.web.name
  source       = "${path.module}/../web/index.html"
  content_type = "text/html"
}

resource "google_storage_bucket_object" "config" {
  name         = "config.js"
  bucket       = google_storage_bucket.web.name
  content_type = "application/javascript"
  content      = "window.APP_CONFIG = { apiUrl: \"${google_cloudfunctions2_function.ask.service_config[0].uri}\" };"
}
