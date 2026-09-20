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

output "jenkins_instance_id" {
  value = module.jenkins.jenkins_instance_id
}

output "ssh_command" {
  value = "ssh -i ${abspath("${path.root}/../../modules/jenkins/keys/jenkins_id_ed25519")} ec2-user@${module.jenkins.jenkins_public_ip}"
}

output "ssm_session_command" {
  value = "aws ssm start-session --target ${module.jenkins.jenkins_instance_id}"
}

output "ssm_status_command" {
  value = "aws ssm describe-instance-information --filters \"Key=InstanceIds,Values=${module.jenkins.jenkins_instance_id}\" --output table"
}

output "jenkins_url" {
  value = "http://${module.jenkins.jenkins_public_ip}:8080"
}