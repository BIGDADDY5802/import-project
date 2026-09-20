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