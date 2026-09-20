# Runbook: Jenkins CI/CD Host — Build, Debug, and Verification

A step-by-step record of standing up the Jenkins host for this project's CI/CD pipeline — network/OIDC/Jenkins provisioning, six real bugs found through live debugging, and the verification steps that confirmed each fix.

*Sensitive values (account ID, real IPs, instance IDs, the admin password) are redacted below and replaced with placeholders in `<ANGLE_BRACKETS>`.*

---

## 1. Initial Provisioning

Staged build — network, OIDC, and Jenkins only, deliberately excluding storage/IAM/compute (those are Jenkins' job to provision later):

```bash
terraform init
terraform plan -target=module.network -target=module.oidc -target=module.jenkins
terraform apply -target=module.network -target=module.oidc -target=module.jenkins
```

**Requirement confirmed:** the Jenkins instance must have `associate_public_ip_address = true` — needed for both direct access and future webhook delivery.

---

## 2. Bug #1 — Missing `associate_public_ip_address`

**Symptom:** `jenkins_public_ip` output resolved empty after apply.

**Cause:** `modules/jenkins/main.tf`'s instance resource never set `associate_public_ip_address`, unlike the app-server module (an inconsistency between two separately-authored modules). Combined with the subnet's `map_public_ip_on_launch = false`, the instance launched with no public IP at all.

**Fix:** added `associate_public_ip_address = true` to `aws_instance.jenkins`. Forced a destroy/replace (launch-time-only attribute).

---

## 3. Bug #2 — Admin IP Drift Locking Out Access

**Symptom:** `curl http://<jenkins_ip>:8080` timed out even after the public IP was confirmed.

**Diagnosis:**
```bash
curl https://checkip.amazonaws.com          # confirm current public IP
aws ec2 describe-security-groups --group-ids <sg-id> \
  --query 'SecurityGroups[0].IpPermissions[?ToPort==`8080`].IpRanges' --output table
```

**Cause:** the security group's trusted IP (`admin_ip_cidr`) was stale — a dynamic home IP had changed since the value was last set.

**Fix:** updated `terraform.tfvars` with the current IP, re-applied. In-place security group update, no instance replacement.

---

## 4. Bug #3 — Root Volume Too Small (2 GB default)

**Symptom:** `user_data` script died partway through; SSM couldn't connect (`TargetNotConnected`); `curl` to `:8080` failed outright.

**Diagnosis — pulled the boot log directly:**
```bash
aws ec2 get-console-output --instance-id <instance-id> --output text
```
Found: `dd: error writing '/swapfile': No space left on device`

**Cause:** `aws_instance.jenkins` had no explicit `root_block_device`, defaulting to a 2 GB volume — far too small for AL2023 + Java 21 + Jenkins + ~35 plugins + a 2 GB swapfile. Script aborted at Step 2/9; Jenkins was never installed.

**Fix:**
```hcl
root_block_device {
  volume_size = 30
  volume_type = "gp3"
  encrypted   = true
}
```
Forced a destroy/replace (both size and encryption are launch-time-only).

---

## 5. Bug #4 — Missing `wget`

**Symptom:** New console-output pull showed the script dying at a different step:
```
[4/9] Adding Jenkins repository...
sudo: wget: command not found
```

**Cause:** Step 1b's package install (`git python3`) never included `wget`, which AL2023 doesn't ship by default. `set -euo pipefail` aborted the whole script at that point.

**Fix attempt #1 (over-corrected):** added both `wget` and `curl` defensively.

**New failure:** `curl` conflicted with AL2023's pre-installed `curl-minimal` package — `yum` refused without `--allowerasing`, aborting at the same step for a different reason.

**Actual fix:** removed `curl` entirely; `curl-minimal` already covers every `curl` usage in the script. Only `wget` was genuinely missing.

---

## 6. Bug #5 — `user_data_replace_on_change` Never Set

**Symptom:** Script edits appeared to apply (`terraform apply` succeeded) but the running instance's behavior never changed.

**Cause:** `user_data_replace_on_change` defaulted to `false`. EC2 only executes `user_data` once, at first boot — editing it and re-applying just updates Terraform's *record* of the value with no effect on an already-running instance (`~ update in-place`, not `-/+ replace`).

**Fix:** added `user_data_replace_on_change = true` to `aws_instance.jenkins`, so any future script edit forces a genuine rebuild.

**Result:** first script fix (`wget`) got past its blocker. Jenkins served real HTML at `:8080` for the first time:
```
Authentication required — permission needed: hudson.model.Hudson.Administer
```
Confirmed: Jenkins running, waiting on the initial admin password.

---

## 7. The SSM Mystery (Two-Day Detour)

**Symptom:** `aws ssm start-session --target <instance-id>` consistently failed with `TargetNotConnected`, across multiple fresh builds.

**Ruled out, one at a time, all confirmed correct:**
- IAM: `AmazonSSMManagedInstanceCore` confirmed attached to `jenkins-role-dev`
- Security group egress: confirmed `0.0.0.0/0` on all ports
- Route table association: confirmed correctly associated
- Instance placement: confirmed correct subnet/security group
- `aws ssm describe-instance-information` for the instance: consistently empty

**Attempted alternate access paths, in order, to get a working shell for direct diagnosis:**
- EC2 Serial Console → dead end (no password ever set for `ec2-user`)
- EC2 Instance Connect → failed ("Error establishing SSH connection")
- Raw TCP test from local machine → `PORT CLOSED/FILTERED` — but this was a **false signal**: the test ran from the admin's own IP, which was never in the security group's Instance Connect–scoped range (`18.206.107.24/29`)

**Breakthrough — widened the port-22 rule to the admin's own IP directly, tested with a real SSH client:**
```bash
ssh -o ConnectTimeout=5 ec2-user@<ip>
```
Result: full SSH handshake completed, rejected only with `Permission denied (publickey)` — proof that `sshd`, the network path, and the security group were all correct. The actual gap was simply *no valid key existed* for this instance.

**Permanent fix — Terraform-generated SSH key pair, auto-written to disk, auto-cleaned on destroy:**
```hcl
resource "tls_private_key" "jenkins" {
  algorithm = "ED25519"
}

resource "aws_key_pair" "jenkins" {
  key_name   = "jenkins-${var.environment}"
  public_key = tls_private_key.jenkins.public_key_openssh
}

resource "local_sensitive_file" "jenkins_private_key" {
  content         = tls_private_key.jenkins.private_key_openssh
  filename        = "${path.module}/keys/jenkins_id_ed25519"
  file_permission = "0400"
}
```
Added `key_name = aws_key_pair.jenkins.key_name` to the instance resource; declared the `local` provider; added `key_name` forced another replace.

`.gitignore` updated to catch key material broadly, not just this one filename:
```
*.pem
*_id_ed25519
*_id_rsa
*.key
keys/
```

**With SSH finally working, the actual SSM root cause was found in under a minute:**
```bash
sudo systemctl status amazon-ssm-agent
# Unit amazon-ssm-agent.service could not be found.
```
**`amazon-ssm-agent` was never installed on this AMI.** The commonly-cited assumption that AL2023 ships it pre-installed was wrong for this specific AMI — and went unverified for two days because no working shell existed to check directly.

**Fix:**
```bash
echo "[1c/9] Installing and starting SSM Agent..."
sudo yum install -y amazon-ssm-agent
sudo systemctl enable amazon-ssm-agent
sudo systemctl start amazon-ssm-agent
```

**Verified, not assumed:**
```bash
aws ssm describe-instance-information --filters "Key=InstanceIds,Values=<instance-id>" --output table
# PingStatus: Online
```

---

## 8. Bug #6 — Terraform CLI Never Installed

**Symptom:** discovered while spot-checking tool availability for the `jenkins` user specifically:
```bash
sudo -u jenkins terraform version
# sudo: terraform: command not found
sudo -u jenkins git --version      # OK
sudo -u jenkins aws --version      # OK
which terraform                    # not found
sudo find / -name terraform -type f  # nothing, anywhere on disk
```

**Cause:** the script's plugin list installs the **Jenkins Terraform plugin**, but the actual Terraform **CLI binary** was never installed — dropped somewhere between an earlier draft and the final script.

**Fix:**
```bash
echo "[6b/9] Installing Terraform CLI..."
sudo yum install -y dnf-plugins-core
sudo dnf config-manager --add-repo https://rpm.releases.hashicorp.com/AmazonLinux/hashicorp.repo
sudo yum install -y terraform
```

**Verified:**
```bash
sudo -u jenkins terraform version
# Terraform v1.16.3
```

---

## 9. Getting the Initial Admin Password

Retrieved from inside a working SSM session (written there automatically by the script's final step):
```bash
aws ssm get-parameter \
  --name "/jenkins/initial-admin-password" \
  --with-decryption --region us-east-1 \
  --query Parameter.Value --output text
```

Unlocked Jenkins at `http://<jenkins_ip>:8080`, created the first real admin account (retiring the temporary unlock password).

---

## 10. Convenience Outputs

Added to `env/dev/outputs.tf` so every future rebuild produces ready-to-paste, fully-interpolated commands — no more manually swapping in IPs or instance IDs:

```hcl
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
```

`abspath()` guarantees the SSH command's key path resolves correctly regardless of which directory it's run from.

**One usage note confirmed during testing:** `ssm_status_command`, if run *from inside* an SSM session on the instance (using the instance's own `jenkins-role-dev` credentials), fails with `AccessDeniedException` — that role was never granted the broader `ssm:DescribeInstanceInformation` action, only the narrow `/jenkins/*` parameter access. This command is meant to be run from the operator's own local machine, not from within the instance's session.

---

## 11. End State — All Six Bugs Fixed, Verified Together

| # | Bug | Fix |
|---|---|---|
| 1 | Missing `associate_public_ip_address` | Added explicitly |
| 2 | Admin IP drift | Updated `terraform.tfvars` |
| 3 | 2 GB root volume | Explicit 30 GB `gp3` encrypted volume |
| 4 | Missing `wget` (and a `curl` over-correction) | Added `wget` only |
| 5 | `user_data_replace_on_change` unset | Set to `true` |
| 6 | `amazon-ssm-agent` never installed | Added explicit install step |
| — | Terraform CLI never installed | Added HashiCorp repo + install step |

**Confirmed working, verified directly rather than assumed, in one clean build:**
- Network, IGW, route table stable
- SSH via Terraform-generated key pair (auto-written, auto-cleaned on destroy)
- SSM Agent registered (`PingStatus: Online`)
- Jenkins UI reachable, unlocked, admin account created
- Terraform CLI present and callable by the `jenkins` user
- Fully-interpolated convenience commands via Terraform outputs

---

## 12. Lessons Worth Carrying Forward

- **`terraform import` and reconciliation can mask bugs that only surface on a genuine from-scratch build.** Several of these bugs were invisible during earlier reconcile-based work and only appeared once `env/dev` was fully destroyed and rebuilt.
- **Don't trust "commonly ships by default" claims about an AMI — verify directly.** Both the SSM agent and Terraform CLI assumptions cost real time because they were treated as settled facts instead of checked.
- **A failed connectivity test isn't proof of a broken system — check what you actually tested.** The `/dev/tcp` port-22 test that came back "CLOSED/FILTERED" was correctly blocked by the security group, not evidence of a deeper problem; it tested from the wrong source IP for what it was trying to prove.
- **Building a genuine shell-access path (the SSH key pair) was the actual unlock for this entire troubleshooting arc.** Every external, from-the-outside diagnostic (IAM checks, security group audits, DNS theories) was necessary but insufficient — direct, inside-the-box verification is what actually closed each bug.

---

*This runbook reflects a personal lab environment built for interview preparation and hands-on CI/CD practice. Account IDs, real IPs, instance IDs, and credentials have been redacted.*