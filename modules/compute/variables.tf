variable "environment" {
  type = string
}

variable "instance_profile_name" {
  description = "IAM instance profile to attach"
  type        = string
}

variable "managed_by" {
  description = "Managed by tag value"
  type        = string
  default     = "terraform"
}

variable "subnet_id" {
  type = string
}

variable "security_group_id" {
  type = string
}

variable "route_table_association_id" {
  type = string
}