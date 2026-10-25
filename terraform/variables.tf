variable "project_id" { type = string }

variable "region" {
  type    = string
  default = "us-central1"
}

variable "zone" {
  type    = string
  default = "us-central1-a"
}

variable "name_prefix" {
  type    = string
  default = "aiops"
}

variable "gemini_model" {
  type    = string
  default = "gemini-3.5-flash-lite" # available in project-d91a0614-922a-445e-96c
}

variable "vertex_location" {
  description = "Location for Vertex AI model endpoints ('global' for Gemini 3/3.5 models)"
  type        = string
  default     = "global"
}

variable "allowed_cidr" {
  description = "Source range allowed to reach the demo app on :8080. Restrict to your IP."
  type        = string
  default     = "0.0.0.0/0"
}

variable "allow_unauthenticated" {
  description = "DEMO ONLY: lets the browser call the function without a token. Replace with Identity Platform + API Gateway."
  type        = bool
  default     = true
}
