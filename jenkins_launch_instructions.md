# Runbook: Launching Infrastructure via Jenkins

Step-by-step instructions for provisioning `storage`/`iam`/`compute` through the Jenkins pipeline job, rather than running Terraform locally.

*Sensitive values (real IPs, instance IDs) are redacted below and replaced with placeholders in `<ANGLE_BRACKETS>`.*

---

## Prerequisites (one-time setup, already complete)

- Jenkins host running, reachable at `http://<jenkins_public_ip>:8080`
- Admin account created and logged in
- `admin-ip-cidr` credential (Secret text) added under **Manage Jenkins → Credentials**
- Pipeline job created, pointed at `terraform_import_plan/Jenkinsfile` in the repo
- `Jenkinsfile` committed and pushed to `main`

---

## Step 1 — Log into Jenkins

```
http://<jenkins_public_ip>:8080
```

Get the current URL if it's changed since last use:
```bash
terraform output -raw jenkins_url
```

---

## Step 2 — Open the pipeline job

From the Jenkins dashboard, click into the job (e.g. `aws-azure-dev-provisioning`).

---

## Step 3 — Start a build with parameters

Click **Build with Parameters** (this option only appears after Jenkins has read the parameterized `Jenkinsfile` at least once — if it's not showing, use **Build Now** instead and it will appear on the next run).

Select the target environment from the **ENVIRONMENT** dropdown:
- `dev`
- `staging`
- `prod`

Click **Build**.

---

## Step 4 — Watch the pipeline run

Click into the running build number, then **Console Output**, to follow along stage by stage:

1. **Checkout** — pulls the repo from GitHub
2. **Terraform Init** — connects to the S3 remote state backend
3. **Terraform Plan** — produces a plan scoped to `module.storage`, `module.iam`, `module.compute`, saved to `tfplan`
4. **Policy Check** — currently a placeholder (tfsec/Checkov not yet wired in)
5. **Manual Approval** — pipeline pauses here

---

## Step 5 — Review the plan before approving

Scroll up in the Console Output to review the full plan Terraform produced in Stage 3. Confirm:
- Resource count and actions match expectations (`X to add, X to change, X to destroy`)
- No unexpected resource is being destroyed or replaced
- Values (bucket name, VPC/subnet references, tags) resolve correctly for the selected environment

---

## Step 6 — Approve or abort

At the **Manual Approval** stage, the pipeline shows:
```
Apply this Terraform plan for <environment>?
[Apply]  [Abort]
```

Click **Apply** to proceed, or **Abort** to stop without making any changes.

---

## Step 7 — Confirm the apply completed

Once approved, the **Terraform Apply** stage runs `terraform apply tfplan` — applying exactly the plan reviewed in Step 5, no re-evaluation, no drift between what was approved and what ran.

Look for:
```
Apply complete! Resources: X added, X changed, X destroyed.

Outputs:
...
```

Build should finish with `Finished: SUCCESS`.

---

## Step 8 — Verify the result

Outputs printed at the end of the Apply stage include the resource IDs created — cross-check against AWS if desired:

```bash
aws ec2 describe-instances --instance-ids <instance_id> \
  --query 'Reservations[0].Instances[0].State.Name' --output text
```

```bash
aws s3api head-bucket --bucket <bucket_name>
```

---

## Known Limitations (current state)

- **`-var` values in the Plan stage are currently hardcoded to `dev`'s specific configuration** (VPC CIDR, bucket name, etc.), regardless of which `ENVIRONMENT` is selected in the dropdown. Selecting `staging` or `prod` today would still target the correct `env/<name>` folder for state, but apply dev's variable *values* — a real gap, not yet safe to run against another environment. Resolving this is the next planned step (Option C: externalized per-environment `.tfvars`, not hardcoded in the `Jenkinsfile`).
- **Policy Check stage does nothing yet** — tfsec and Checkov are installed on the Jenkins host but not yet invoked in the pipeline.
- **Pipeline only provisions `storage`/`iam`/`compute`** — `network`, `oidc`, and `jenkins` itself remain under direct local Terraform control, by design, since Jenkins provisioning its own underlying infrastructure mid-pipeline is a circular dependency worth avoiding.

---

*This runbook reflects a personal lab environment built for interview preparation and hands-on CI/CD practice. Real IPs, instance IDs, and account-specific values have been redacted.*