variable "environment" {
  description = "Environment name (dev/staging/prod)"
  type        = string
}

variable "app_assets_bucket_arn" {
  description = "ARN of the app assets S3 bucket this role needs access to"
  type        = string
}

variable "managed_by" {
  description = "Managed by tag value"
  type        = string
  default     = "terraform"
}