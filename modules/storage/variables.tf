variable "bucket_name" {
  description = "Name of the app assets bucket"
  type        = string
}

variable "environment" {
  description = "Environment name (dev/staging/prod)"
  type        = string
}

variable "managed_by" {
  description = "Managed by tag value"
  type        = string
  default     = "terraform"
}