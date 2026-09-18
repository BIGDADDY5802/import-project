variable "environment" {
  type = string
}

variable "admin_ip_cidr" {
  description = "Your IP in CIDR form, e.g. 203.0.113.5/32"
  type        = string
}

variable "managed_by" {
  description = "Managed by tag value"
  type        = string
  default     = "terraform"
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
}

variable "subnet_cidr" {
  description = "CIDR block for the subnet"
  type        = string
}

variable "availability_zone" {
  description = "AZ for the subnet"
  type        = string
}

variable "vpc_name" {
  description = "Name tag for the VPC"
  type        = string
}

variable "subnet_name" {
  description = "Name tag for the subnet"
  type        = string
}

variable "igw_name" {
  type    = string
  default = "app-igw"
}

variable "route_table_name" {
  type    = string
  default = "app-public-rt"
}