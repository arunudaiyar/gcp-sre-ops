output "web_url" { value = "https://storage.googleapis.com/${google_storage_bucket.web.name}/index.html" }
output "function_url" { value = google_cloudfunctions2_function.ask.service_config[0].uri }
output "app_url" { value = "http://${google_compute_instance.app.network_interface[0].access_config[0].nat_ip}:8080" }
