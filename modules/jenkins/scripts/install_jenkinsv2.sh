#!/bin/bash
set -euo pipefail

# =============================================================================
# Jenkins Bootstrap Script
# Amazon Linux 2023 (AL2023) — t3.medium
# Note: intentionally uses yum for Jenkins repo compatibility
# =============================================================================


# --------------------------------------
# Update all installed packages
# --------------------------------------
echo "[1/10] Updating system packages..."
sudo yum update -y


# --------------------------------------
# Install essential binaries
# git     — required by Jenkins to clone repos
# python3 — required by various Jenkins plugins and scripts
# wget    — needed to fetch the Jenkins repo file and plugin manager jar
# --------------------------------------
echo "[1b/10] Installing essential binaries..."
sudo yum install -y git python3 wget

echo "[1c/10] Installing and starting SSM Agent..."
sudo yum install -y amazon-ssm-agent
sudo systemctl enable amazon-ssm-agent
sudo systemctl start amazon-ssm-agent


# --------------------------------------
# Configure swap (AL2023 has none by default)
# 2GB swapfile — prevents OOM kills during heavy Jenkins builds
# --------------------------------------
echo "[2/10] Configuring swap..."
if [ ! -f /swapfile ]; then
  sudo dd if=/dev/zero of=/swapfile bs=128M count=16
  sudo chmod 600 /swapfile
  sudo mkswap /swapfile
  sudo swapon /swapfile
  echo '/swapfile swap swap defaults 0 0' | sudo tee -a /etc/fstab
fi


# --------------------------------------
# Expand /tmp to 4GB via systemd drop-in
# AL2023 mounts /tmp as tmpfs via systemd tmp.mount — fstab remount
# is overridden at boot by the systemd unit. A drop-in override persists.
# --------------------------------------
echo "[3/10] Expanding /tmp..."
sudo mkdir -p /etc/systemd/system/tmp.mount.d

cat << 'EOF' | sudo tee /etc/systemd/system/tmp.mount.d/size.conf
[Mount]
Options=mode=1777,strictatime,nosuid,nodev,size=4G
EOF

sudo systemctl daemon-reload
sudo systemctl restart tmp.mount


# --------------------------------------
# Add the Jenkins repository to yum sources
# --------------------------------------
echo "[4/10] Adding Jenkins repository..."
sudo wget -O /etc/yum.repos.d/jenkins.repo https://pkg.jenkins.io/redhat-stable/jenkins.repo


# --------------------------------------
# Import the Jenkins GPG key to verify packages
# --------------------------------------
sudo rpm --import https://pkg.jenkins.io/redhat-stable/jenkins.io-2023.key


# --------------------------------------
# Upgrade all packages (including those from the new Jenkins repo)
# --------------------------------------
sudo yum upgrade -y


# --------------------------------------
# Install Amazon Corretto 21 (LTS — Java 17 EOL March 31 2026)
# --------------------------------------
echo "[5/10] Installing Java 21..."
sudo yum install java-21-amazon-corretto -y


# --------------------------------------
# Install Jenkins
# --------------------------------------
echo "[6/10] Installing Jenkins..."
sudo yum install jenkins -y


# --------------------------------------
# Install Terraform CLI
# Needed for the terraform Jenkins plugin to actually have a binary to call
# --------------------------------------
echo "[6b/10] Installing Terraform CLI..."
sudo yum install -y dnf-plugins-core
sudo dnf config-manager --add-repo https://rpm.releases.hashicorp.com/AmazonLinux/hashicorp.repo
sudo yum install -y terraform


# =============================================================================
# Plugin Installation
# Uses the Plugin Installation Manager Tool (plugin-installation-manager-tool)
# jenkins-plugin-cli is not bundled with Jenkins 2.x rpm packages
# =============================================================================

echo "[7/10] Installing Jenkins plugins..."

JENKINS_HOME="${JENKINS_HOME:-/var/lib/jenkins}"
PLUGIN_DIR="${JENKINS_HOME}/plugins"
PLUGIN_MANAGER_JAR="/usr/local/bin/jenkins-plugin-manager.jar"

sudo mkdir -p "$PLUGIN_DIR"

# Download the Plugin Installation Manager jar
echo "[7/10] Downloading plugin installation manager..."
sudo wget -q -O "$PLUGIN_MANAGER_JAR" \
  https://github.com/jenkinsci/plugin-installation-manager-tool/releases/download/2.13.0/jenkins-plugin-manager-2.13.0.jar

# Write the plugin list to a temp file
PLUGIN_LIST_FILE=$(mktemp /tmp/jenkins-plugins-XXXXXX.txt)

cat > "$PLUGIN_LIST_FILE" << 'EOF'
# AWS
aws-credentials
pipeline-aws
ec2
amazon-ecs
codedeploy
aws-lambda
aws-codebuild
artifact-manager-s3
aws-secrets-manager-credentials-provider
aws-codepipeline
configuration-as-code-secret-ssm
aws-sam

# IaC
terraform
kubernetes

# Google Cloud
google-storage-plugin
google-kubernetes-engine
google-oauth-plugin

# Security Scanning
snyk-security-scanner
sonar
aqua-security-scanner
aqua-microscanner
aqua-serverless

# GitHub
github
github-oauth
pipeline-github
pipeline-githubnotify-step

# Build & Deploy
maven-plugin
pipeline-maven
publish-over-ssh
EOF

# --skip-failed-plugins skips unresolvable plugins and continues the rest
# --jenkins-update-center bypasses the default 301 redirect to the current index
sudo java -jar "$PLUGIN_MANAGER_JAR" \
  --war /usr/share/java/jenkins.war \
  --plugin-file "$PLUGIN_LIST_FILE" \
  --plugin-download-directory "$PLUGIN_DIR" \
  --jenkins-update-center https://updates.jenkins.io/current/update-center.json \
  --skip-failed-plugins

echo "[7b/10] Verifying plugin downloads..."
EXPECTED=$(grep -v '^#' "$PLUGIN_LIST_FILE" | grep -c .)
ACTUAL=$(find "$PLUGIN_DIR" -maxdepth 1 -name '*.jpi' | wc -l)
echo "Requested: $EXPECTED top-level plugins | Found on disk: $ACTUAL files (includes dependencies)"

rm -f "$PLUGIN_LIST_FILE"

# Fix ownership so Jenkins can read the installed plugins
sudo chown -R jenkins:jenkins "$PLUGIN_DIR"

echo "[7/10] Plugin installation complete."


# --------------------------------------
# Enable Jenkins to start at boot
# --------------------------------------
echo "[8/10] Enabling Jenkins service..."
sudo systemctl enable jenkins


# =============================================================================
# Skip the setup wizard entirely — generate and store the admin password
# BEFORE Jenkins ever starts, then create the account via a Groovy init
# script. Idempotent: safe to run on every boot without erroring or
# duplicating the account.
# =============================================================================

echo "[8b/10] Generating and storing admin password..."
ADMIN_PASSWORD=$(openssl rand -base64 24)

aws ssm put-parameter \
  --name "/jenkins/initial-admin-password" \
  --value "$ADMIN_PASSWORD" \
  --type "SecureString" \
  --overwrite \
  --region us-east-1

echo "[8c/10] Configuring Jenkins to skip setup wizard..."
sudo mkdir -p /var/lib/jenkins/init.groovy.d
echo "2.0" | sudo tee /var/lib/jenkins/jenkins.install.UpgradeWizard.state
echo "2.0" | sudo tee /var/lib/jenkins/jenkins.install.InstallUtil.lastExecVersion

sudo tee /var/lib/jenkins/init.groovy.d/basic-security.groovy > /dev/null << GROOVY
import jenkins.model.*
import hudson.security.*

def instance = Jenkins.getInstance()
def hudsonRealm = instance.getSecurityRealm()

if (!(hudsonRealm instanceof HudsonPrivateSecurityRealm) || !hudsonRealm.getAllUsers().find { it.id == 'admin' }) {
  def newRealm = new HudsonPrivateSecurityRealm(false)
  newRealm.createAccount('admin', '${ADMIN_PASSWORD}')
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

sudo chown -R jenkins:jenkins /var/lib/jenkins/init.groovy.d


# --------------------------------------
# Start the Jenkins service
# --------------------------------------
echo "[9/10] Starting Jenkins..."
sudo systemctl start jenkins


# --------------------------------------
# Wait for Jenkins to actually come up, then remove the Groovy init script.
# It only needs to exist for this one boot — once the admin account is
# created, leaving a plaintext password sitting in init.groovy.d forever
# is an unnecessary, easily-forgotten exposure. The password itself
# remains retrievable from SSM for anyone who legitimately needs it.
# --------------------------------------
echo "[9b/10] Waiting for Jenkins to come up before cleaning up init script..."
RETRIES=0
until curl -s -o /dev/null http://localhost:8080/login || [ "$RETRIES" -ge 60 ]; do
  sleep 5
  RETRIES=$((RETRIES + 1))
done

if curl -s -o /dev/null http://localhost:8080/login; then
  sudo rm -f /var/lib/jenkins/init.groovy.d/basic-security.groovy
  echo "[9b/10] Groovy init script removed — admin account already created."
else
  echo "WARNING: Jenkins did not respond within the wait window — leaving init script in place for retry on next restart."
fi

echo "============================================"
echo " Jenkins bootstrap complete."
echo " Admin username: admin"
echo " Admin password stored in SSM: /jenkins/initial-admin-password"
echo "============================================"