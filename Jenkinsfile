pipeline {
    agent any

    parameters {
        choice(
            name: 'ENVIRONMENT',
            choices: ['dev', 'staging', 'prod'],
            description: 'Which environment this pipeline run targets'
        )
    }

    environment {
        AWS_REGION = 'us-east-1'
        TF_DIR     = "env/${params.ENVIRONMENT}"
        ADMIN_IP_CIDR = credentials('admin-ip-cidr')
    }

    stages {
        stage('Checkout') {
            steps {
                checkout scm
            }
        }

        stage('Terraform Init') {
            steps {
                dir(env.TF_DIR) {
                    sh 'terraform init'
                }
            }
        }

        stage('Terraform Plan') {
            steps {
                dir(env.TF_DIR) {
                    sh '''
                        terraform plan \
                          -var="admin_ip_cidr=${ADMIN_IP_CIDR}" \
                          -var="vpc_cidr=10.190.0.0/16" \
                          -var="subnet_cidr=10.190.20.0/24" \
                          -var="availability_zone=us-east-1b" \
                          -var="vpc_name=migrated-vpc" \
                          -var="subnet_name=migrated-subnet" \
                          -var="environment=${ENVIRONMENT}" \
                          -var="bucket_name=app-assets-project" \
                          -var="github_org=BIGDADDY5802" \
                          -var="github_repo=import-project" \
                          -target=module.storage \
                          -target=module.iam \
                          -target=module.compute \
                          -out=tfplan
                    '''
                }
            }
        }

        stage('Policy Check') {
            steps {
                dir(env.TF_DIR) {
                    echo 'Policy check stage — tfsec/Checkov to be added here.'
                }
            }
        }

        stage('Manual Approval') {
            steps {
                input message: "Apply this Terraform plan for ${params.ENVIRONMENT}?", ok: 'Apply'
            }
        }

        stage('Terraform Apply') {
            steps {
                dir(env.TF_DIR) {
                    sh 'terraform apply tfplan'
                }
            }
        }
    }

    post {
        always {
            dir(env.TF_DIR) {
                sh 'rm -f tfplan'
            }
        }
    }
}