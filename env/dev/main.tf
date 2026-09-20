terraform {
  required_providers {
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }

    local = {
      source  = "hashicorp/local"
      version = "~> 2.0"
    }

  }
}

provider "aws" {
  region = "us-east-1"
}

module "storage" {
  source      = "../../modules/storage"
  bucket_name = var.bucket_name
  environment = var.environment
}

module "iam" {
  source                = "../../modules/iam"
  environment           = var.environment
  app_assets_bucket_arn = module.storage.bucket_arn
}

module "compute" {
  source                     = "../../modules/compute"
  environment                = var.environment
  instance_profile_name      = module.iam.instance_profile_name
  subnet_id                  = module.network.subnet_id
  security_group_id          = module.network.security_group_id
  route_table_association_id = module.network.route_table_association_id
}

module "network" {
  source            = "../../modules/network"
  environment       = var.environment
  admin_ip_cidr     = var.admin_ip_cidr
  vpc_cidr          = var.vpc_cidr
  subnet_cidr       = var.subnet_cidr
  availability_zone = var.availability_zone
  vpc_name          = var.vpc_name
  subnet_name       = var.subnet_name
}

module "oidc" {
  source        = "../../modules/oidc"
  github_org    = var.github_org
  github_repo   = var.github_repo
  github_branch = "main"
}

module "jenkins" {
  source        = "../../modules/jenkins"
  environment   = var.environment
  vpc_id        = module.network.vpc_id
  subnet_id     = module.network.subnet_id
  admin_ip_cidr = var.admin_ip_cidr
}