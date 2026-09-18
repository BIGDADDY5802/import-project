variable "admin_ip_cidr" {
  description = "Your IP in CIDR form, e.g. 203.0.113.5/32"
  type        = string
}

variable "vpc_cidr" {
  type = string
}

variable "subnet_cidr" {
  type = string
}

variable "availability_zone" {
  type = string
}

variable "vpc_name" {
  type = string
}

variable "subnet_name" {
  type = string
}

variable "environment" {
  type = string
}

variable "bucket_name" {
  type = string
}

variable "github_org" {
  type = string
}

variable "github_repo" {
  type = string
}