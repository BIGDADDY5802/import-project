variable "state_bucket_name" {
  description = "Globally unique name for the Terraform state bucket"
  type        = string
}

variable "lock_table_name" {
  description = "Name for the DynamoDB lock table"
  type        = string
  default     = "terraform-locks"
}

variable "aws_region" {
  type    = string
  default = "us-east-1"
}