# Runbook: Configuring the Jenkins Instance

Steps taken to unlock and configure the Jenkins host after a successful `terraform apply`, plus the planned upgrade that removes the manual unlock step going forward.

*Sensitive values (the admin password, real IPs) are redacted below and replaced with placeholders in `<ANGLE_BRACKETS>`.*

---

## 1. Retrieve the Initial Admin Password

Written to SSM Parameter Store by the bootstrap script's final step:

```bash
aws ssm get-parameter \
  --name "/jenkins/initial-admin-password" \
  --with-decryption \
  --region us-east-1 \
  --query Parameter.Value --output text
```

**Sanity-checked tool availability on the host at the same time**, confirming everything the pipeline depends on is actually present and callable by the `jenkins` user specifically (not just the OS in general):

```bash
sudo -u jenkins terraform version
sudo -u jenkins git --version
sudo -u jenkins aws --version
```

---

## 2. Unlock Jenkins

Navigated to:
```
http://<jenkins_public_ip>:8080
```

Pasted the retrieved password into the "Unlock Jenkins" screen.

**Created the first real admin account** (replacing reliance on the temporary unlock credential):
- Username: `admin`
- Password: `<REDACTED>`

**Instance Configuration — Jenkins URL:**
```
http://<jenkins_public_ip>:8080/
```
Confirmed as the root URL Jenkins uses for absolute links (email notifications, PR status updates, the `BUILD_URL` environment variable available to build steps). Left at the proposed default, generated from the current request.

---

## 3. Planned Upgrade — Skip the Setup Wizard Entirely

The manual unlock flow above (retrieve password → paste into wizard → create admin account by hand) is scheduled to be replaced by a fully automated, idempotent boot flow already written and staged in `install_jenkins.sh` (not yet applied to the live instance):

**What changes:**
- The admin password is generated with `openssl rand -base64 24` **before** Jenkins ever starts, and written to SSM immediately — no dependency on Jenkins' own internal password generation.
- The setup wizard is skipped entirely via `jenkins.install.UpgradeWizard.state` / `jenkins.install.InstallUtil.lastExecVersion`, both pre-set to `2.0`.
- A Groovy init script (`/var/lib/jenkins/init.groovy.d/basic-security.groovy`) creates the `admin` account automatically at boot, **idempotently** — it checks whether the account already exists before creating one, so reruns or instance replacements never error or duplicate the account.
- Jenkins goes straight to the login screen on first boot — no manual unlock step, no interactive wizard window where an unauthenticated visitor could theoretically reach the instance first.

**Security tradeoff considered and closed:** generating the password upfront and embedding it in a Groovy file on disk introduced a new exposure — a plaintext credential sitting in `init.groovy.d/` indefinitely, easy to forget about since it doesn't look like a "credential file." Closed by having the script wait for Jenkins to actually come up, then delete the Groovy file once the account is confirmed created:

```bash
until curl -s -o /dev/null http://localhost:8080/login || [ "$RETRIES" -ge 60 ]; do
  sleep 5
  RETRIES=$((RETRIES + 1))
done

if curl -s -o /dev/null http://localhost:8080/login; then
  sudo rm -f /var/lib/jenkins/init.groovy.d/basic-security.groovy
fi
```

If Jenkins doesn't respond within the wait window, the script leaves the file in place rather than deleting it blindly — preserves the idempotent creation logic for a future retry instead of silently losing it.

**Net result once applied:** no manual unlock step, no interactive wizard window, no lingering plaintext credential file — the password remains retrievable only through SSM, the same as today, but the whole account-creation flow becomes a single automated pass with no human step in between boot and a working login.

**Not yet applied** — this is staged in the script but requires the next Jenkins instance rebuild (`user_data_replace_on_change = true` will force it automatically) to take effect.

---

## Open Items

- [ ] Apply the no-wizard boot flow on the next rebuild and verify: password in SSM before Jenkins starts, Groovy script creates the account, Groovy script removed after confirmed startup
- [ ] Externalize per-environment `.tfvars` for the Jenkins pipeline (Option C from the CI/CD runbook) — currently hardcoded to dev's values
- [ ] Wire tfsec/Checkov into the Policy Check pipeline stage (currently a placeholder)

---

*This runbook reflects a personal lab environment built for interview preparation and hands-on CI/CD practice. Real IPs and credentials have been redacted.*