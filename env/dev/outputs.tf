output "instance_id" {
  value = module.compute.instance_id
}

output "bucket_name" {
  value = module.storage.bucket_name
}

output "vpc_id" {
  value = module.network.vpc_id
}

output "security_group_id" {
  value = module.network.security_group_id
}

output "cicd_role_arn" {
  value = module.oidc.cicd_role_arn
}

output "jenkins_public_ip" {
  value = module.jenkins.jenkins_public_ip
}