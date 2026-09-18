#!/bin/bash
set -e

# ── Java (required by Jenkins) ──────────────────────────────
dnf install -y java-21-amazon-corretto

# ── Jenkins itself ───────────────────────────────────────────
wget -O /etc/yum.repos.d/jenkins.repo https://pkg.jenkins.io/redhat-stable/jenkins.repo
rpm --import https://pkg.jenkins.io/redhat-stable/jenkins.io-2023.key
dnf install -y jenkins

# ── Core CLI tools used daily ────────────────────────────────
dnf install -y git jq unzip wget curl

# ── Python 3 + pip ────────────────────────────────────────────
dnf install -y python3 python3-pip

# ── AWS CLI v2 (dnf's version lags — install the official binary) ──
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
unzip -q awscliv2.zip
./aws/install
rm -rf awscliv2.zip aws/

# ── Terraform CLI ─────────────────────────────────────────────
dnf install -y dnf-plugins-core
dnf config-manager --add-repo https://rpm.releases.hashicorp.com/AmazonLinux/hashicorp.repo
dnf install -y terraform

# ── Docker (needed by several scanners, and generally useful) ──
dnf install -y docker
systemctl enable docker
systemctl start docker
usermod -aG docker jenkins

# ── Security scanners ────────────────────────────────────────
# tfsec — Terraform static analysis
curl -s https://raw.githubusercontent.com/aquasecurity/tfsec/master/scripts/install_linux.sh | bash

# Checkov — IaC policy scanning (Python-based, install via pip)
pip3 install checkov

# Gitleaks — secret scanning
GITLEAKS_VERSION="8.21.2"
curl -sL "https://github.com/gitleaks/gitleaks/releases/download/v${GITLEAKS_VERSION}/gitleaks_${GITLEAKS_VERSION}_linux_x64.tar.gz" -o gitleaks.tar.gz
tar -xzf gitleaks.tar.gz gitleaks
mv gitleaks /usr/local/bin/
rm -f gitleaks.tar.gz

# TruffleHog — secret scanning
curl -sSfL https://raw.githubusercontent.com/trufflesecurity/trufflehog/main/scripts/install.sh | sh -s -- -b /usr/local/bin

# Snyk — dependency/vuln scanning (npm-based, needs Node first)
dnf install -y nodejs
npm install -g snyk

# ── Jenkins plugins, installed headlessly on first boot ──────
JENKINS_PLUGIN_DIR="/var/lib/jenkins/plugins"
mkdir -p "$JENKINS_PLUGIN_DIR"

curl -sL https://github.com/jenkinsci/plugin-installation-manager-tool/releases/latest/download/jenkins-plugin-manager.jar \
  -o /opt/jenkins-plugin-manager.jar

cat > /tmp/plugins.txt << 'EOF'
git
pipeline-stage-view
workflow-aggregator
credentials-binding
aws-credentials
terraform
blueocean
ansicolor
EOF

java -jar /opt/jenkins-plugin-manager.jar \
  --war /usr/share/java/jenkins.war \
  --plugin-file /tmp/plugins.txt \
  --plugin-download-directory "$JENKINS_PLUGIN_DIR"

chown -R jenkins:jenkins "$JENKINS_PLUGIN_DIR"

# ── Start Jenkins last, once everything's in place ────────────
systemctl enable jenkins

# ── Skip the setup wizard entirely ─────────────────────────────
mkdir -p /var/lib/jenkins/init.groovy.d
mkdir -p /var/lib/jenkins/
echo "2.0" > /var/lib/jenkins/jenkins.install.UpgradeWizard.state
echo "2.0" > /var/lib/jenkins/jenkins.install.InstallUtil.lastExecVersion

# ── Fetch the admin password from Secrets Manager (never in plaintext here) ──
JENKINS_ADMIN_PASSWORD=$(aws secretsmanager get-secret-value \
  --secret-id "jenkins-admin-password-${environment}" \
  --query SecretString --output text --region us-east-1)

# ── Idempotent admin user creation via Groovy init script ─────
cat > /var/lib/jenkins/init.groovy.d/basic-security.groovy << GROOVY
import jenkins.model.*
import hudson.security.*

def instance = Jenkins.getInstance()
def hudsonRealm = instance.getSecurityRealm()

if (!(hudsonRealm instanceof HudsonPrivateSecurityRealm) || !hudsonRealm.getAllUsers().find { it.id == 'admin' }) {
  def newRealm = new HudsonPrivateSecurityRealm(false)
  newRealm.createAccount('admin', '${JENKINS_ADMIN_PASSWORD}')
  instance.setSecurityRealm(newRealm)

  def strategy = new FullControlOnceLoggedInAuthorizationStrategy()
  strategy.setAllowAnonymousRead(false)
  instance.setAuthorizationStrategy(strategy)

  instance.save()
  println "Admin account created."
} else {
  println "Admin account already exists — skipping."
}
GROOVY

chown -R jenkins:jenkins /var/lib/jenkins/init.groovy.d

systemctl start jenkins