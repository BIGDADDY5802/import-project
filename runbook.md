# ClickOps-to-Terraform Migration Log: Dev Environment

A step-by-step record of migrating a hand-built ("ClickOps") AWS environment into fully Terraform-managed infrastructure — bootstrap, storage, IAM, compute, and networking — using `terraform import` to bring existing resources under management without recreating them.

*Sensitive values (account ID, real IPs, resource IDs) have been redacted below and replaced with placeholders in `<ANGLE_BRACKETS>`.*

---

## 1. Project Structure

```
project/
├── bootstrap/
│   ├── main.tf
│   ├── variables.tf
│   ├── outputs.tf
│   └── terraform.tfvars          ← bootstrap's own values, local state only
│
├── modules/
│   ├── network/
│   ├── compute/
│   ├── iam/
│   └── storage/                  ← reusable blueprints, NO tfvars here, ever
│
└── env/
    ├── dev/
    │   ├── main.tf                ← calls the modules
    │   ├── backend.tf
    │   ├── variables.tf
    │   └── terraform.tfvars       ← dev's own values
    ├── staging/                    ← not yet built
    └── prod/                       ← not yet built
```

**Key terms used throughout:**

| Term | Meaning |
|---|---|
| **Bootstrap** | One-time setup of Terraform's own plumbing (state bucket + lock table) before any real workloads are managed |
| **Import** | Bringing an already-existing resource (built by ClickOps or otherwise) under Terraform's management, without recreating it |
| **Migration** | The broader activity of moving a workload from one state to another — import is one tool used during a migration |

---

## 2. Bootstrap: Remote State Backend

Terraform can't store its own state in a backend that doesn't exist yet — so the bucket and lock table that hold Terraform's state have to be created first, using **local** state only.

```hcl
provider "aws" {
  region = var.aws_region
}

resource "aws_s3_bucket" "tf_state" {
  bucket = var.state_bucket_name

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_versioning" "tf_state" {
  bucket = aws_s3_bucket.tf_state.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "tf_state" {
  bucket = aws_s3_bucket.tf_state.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "tf_state" {
  bucket                  = aws_s3_bucket.tf_state.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_dynamodb_table" "tf_locks" {
  name         = var.lock_table_name
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"

  attribute {
    name = "LockID"
    type = "S"
  }
}
```

Run from `bootstrap/`:
```bash
terraform init
terraform plan -out=tfplan
terraform apply "tfplan"
```

`prevent_destroy = true` guards against accidentally deleting Terraform's own state storage with a stray `destroy` elsewhere.

---

## 3. Storage Module: Import & Harden the App Bucket

**Step 1 — Init the env:**
```bash
cd env/dev
terraform init
```

**Step 2 — Write module code matching the existing bucket**, then call it from `env/dev/main.tf`.

**Step 3 — Import:**
```bash
terraform import module.storage.aws_s3_bucket.app_assets <BUCKET_NAME>
```

**Step 4 — Reconcile:**
```bash
terraform plan
```
First plan showed a tag diff (the ClickOps bucket had no tags) — applied as a deliberate improvement, not a mismatch to chase:
```bash
terraform apply
```

**Step 5 — Harden**, once import was tracked cleanly:

```hcl
resource "aws_s3_bucket_versioning" "app_assets" {
  bucket = aws_s3_bucket.app_assets.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "app_assets" {
  bucket = aws_s3_bucket.app_assets.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "app_assets" {
  bucket                  = aws_s3_bucket.app_assets.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}
```

```bash
terraform apply
```

**Result:** bucket went from untagged/unencrypted/unversioned/potentially-public to fully tagged, encrypted, versioned, and locked from public access — all under Terraform management.

---

## 4. IAM Module: Replace the Admin User with a Least-Privilege Role

The ClickOps environment had an IAM **user** with `AdministratorAccess` attached directly to the app. Rather than import and modify that user, the fix was to build the *correct* pattern fresh — a scoped role + instance profile — and retire the admin user once the replacement was proven to work.

```hcl
# Trust policy: only EC2 instances can assume this role
data "aws_iam_policy_document" "assume_role" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "app_role" {
  name               = "app-role-${var.environment}"
  assume_role_policy = data.aws_iam_policy_document.assume_role.json

  tags = {
    Environment = var.environment
  }
}

# Scoped policy: only what the app actually needs — read/write to its own bucket
data "aws_iam_policy_document" "app_policy" {
  statement {
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:ListBucket",
    ]
    resources = [
      var.app_assets_bucket_arn,
      "${var.app_assets_bucket_arn}/*",
    ]
  }
}

resource "aws_iam_role_policy" "app_policy" {
  name   = "app-policy-${var.environment}"
  role   = aws_iam_role.app_role.id
  policy = data.aws_iam_policy_document.app_policy.json
}

resource "aws_iam_instance_profile" "app_profile" {
  name = "app-profile-${var.environment}"
  role = aws_iam_role.app_role.name
}
```

```bash
terraform apply -target=module.iam
```

**Verification, once the profile was attached to the running instance:**
```bash
aws sts get-caller-identity          # confirms role, not the deleted user
aws s3 ls s3://<BUCKET_NAME>         # confirms scoped access actually works
```

**Admin user removed** directly in the console once the instance was confirmed working on the new role — no state to reconcile, since the user was never imported.

---

## 5. Compute Module: Import the EC2 Instance

**Step 1 — Write module code matching the real instance** (real AMI ID, instance type), then call it from `env/dev/main.tf`, wired to the IAM module's `instance_profile_name` output.

**Step 2 — Import** (using the real instance ID, not the AMI ID — an early mix-up caught before applying and creating a duplicate):
```bash
terraform import module.compute.aws_instance.app_server <INSTANCE_ID>
```

**Step 3 — Externalize the startup script.** The original `user_data` was embedded as a heredoc string in `main.tf`; moved into its own file for readability:

```
modules/compute/
└── scripts/
    └── user_data_a.sh
```

```hcl
resource "aws_instance" "app_server" {
  ami                  = "<AMI_ID>"
  instance_type        = "t3.micro"
  iam_instance_profile = var.instance_profile_name
  user_data            = file("${path.module}/scripts/user_data_a.sh")

  tags = {
    Name        = "app-server-${var.environment}"
    Environment = var.environment
  }
}
```

**Step 4 — Reconcile:**
```bash
terraform plan
```
Result: `user_data` dropped out of the diff entirely (byte-for-byte match with the running instance). Remaining changes — `iam_instance_profile` attaching and tags correcting — applied cleanly:
```bash
terraform apply
```

---

## 6. Network Module: Security Group — Import, Then Lock Down SSH

**Get the public IP that needs SSH access:**
```bash
curl https://checkip.amazonaws.com
```

**Step 1 — Write module code matching the currently-open rule exactly** (`0.0.0.0/0` on port 22) before touching anything — matching reality first avoids a noisy, hard-to-read diff.

```hcl
resource "aws_security_group" "app_sg" {
  name        = "<SG_NAME>"
  description = "<EXACT_EXISTING_DESCRIPTION>"   # AWS SG description is immutable — mismatch here forces a destroy/replace

  ingress {
    description = "SSH - TEMP, open, will be tightened"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name        = "app-sg-${var.environment}"
    Environment = var.environment
  }
}
```

**Step 2 — Import:**
```bash
terraform import module.network.aws_security_group.app_sg <SECURITY_GROUP_ID>
```

**Step 3 — Reconcile to zero-diff.** First `plan` came back as `-/+ destroy and then create replacement` — caught before applying. Cause: the `description` field didn't match the live value exactly, and AWS treats security group descriptions as immutable, forcing Terraform to plan a full replace. Fixed by matching the description (and an extra port-80 ingress rule the module hadn't declared) exactly:
```bash
terraform plan   # confirmed clean update-in-place, no replacement
terraform apply
```

**Step 4 — The actual fix, applied deliberately as a second step:**
```hcl
ingress {
  description = "SSH from admin IP only"
  from_port   = 22
  to_port     = 22
  protocol    = "tcp"
  cidr_blocks = [var.admin_ip_cidr]   # was ["0.0.0.0/0"]
}
```
```bash
terraform plan    # confirmed only the CIDR/description changed, no replacement
terraform apply
```

**Result:** SSH access closed off from the entire internet, restricted to a single admin IP — done as an auditable, reviewable code change instead of a silent console edit.

---

## 7. Network Module: VPC & Subnet Import

**Pull real values via CLI rather than the console:**

```bash
aws ec2 describe-vpcs --vpc-ids <VPC_ID>
aws ec2 describe-vpc-attribute --vpc-id <VPC_ID> --attribute enableDnsSupport
aws ec2 describe-vpc-attribute --vpc-id <VPC_ID> --attribute enableDnsHostnames

aws ec2 describe-subnets --filters "Name=vpc-id,Values=<VPC_ID>" \
  --query 'Subnets[].{ID:SubnetId,CIDR:CidrBlock,AZ:AvailabilityZone,PublicIP:MapPublicIpOnLaunch}' \
  --output table

aws ec2 describe-instances --instance-ids <INSTANCE_ID> \
  --query 'Reservations[0].Instances[0].SubnetId' --output text

aws ec2 describe-subnets --subnet-ids <SUBNET_ID> --query 'Subnets[0].Tags' --output table
```

**Values captured (redacted):**
- VPC CIDR: `10.190.0.0/16`, DNS support & hostnames both enabled, tagged `Name: no-name-vpc`
- Target subnet: AZ `us-east-1b`, CIDR `10.190.20.0/24`, not public-IP-assigning, tagged `Name: no-name-subnet-public2-us-east-1b`

**Parameterized via variables instead of hardcoding**, since CIDR/AZ/naming are exactly the kind of values that differ per environment:

```hcl
# modules/network/variables.tf
variable "vpc_cidr"           { type = string }
variable "subnet_cidr"        { type = string }
variable "availability_zone"  { type = string }
variable "vpc_name"           { type = string }
variable "subnet_name"        { type = string }
```

```hcl
# modules/network/main.tf
resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags = { Name = var.vpc_name }
}

resource "aws_subnet" "main" {
  vpc_id                  = aws_vpc.main.id
  cidr_block               = var.subnet_cidr
  availability_zone         = var.availability_zone
  map_public_ip_on_launch   = false
  tags = { Name = var.subnet_name }
}
```

Same five-file variable chain used throughout the project: module `variables.tf` declares → env `variables.tf` declares → env `terraform.tfvars` supplies real values → env `main.tf` passes them into the module call.

**Import both:**
```bash
terraform import module.network.aws_vpc.main <VPC_ID>
terraform import module.network.aws_subnet.main <SUBNET_ID>
```

**Reconcile and rename in the same pass** — CIDR, AZ, and DNS settings matched exactly on the first plan (confirming the CLI-sourced values were correct); only the `Name` tags were deliberately changed as part of this same apply:
```hcl
vpc_name    = "migrated-vpc"
subnet_name = "migrated-subnet"
```
```bash
terraform plan     # 0 to add, 2 to change, 0 to destroy — both tag-only, both in-place
terraform apply
```

---

## 8. End State

| Resource | Status |
|---|---|
| Terraform state backend | Self-hosted (S3 + DynamoDB), built by Terraform itself |
| S3 app bucket | Imported, tagged, encrypted, versioned, public access blocked |
| IAM | Admin user retired; least-privilege role + instance profile in place |
| EC2 instance | Imported, IAM role attached, startup script version-controlled |
| Security group | Imported, SSH restricted to a single admin IP, no forced replacement |
| VPC & subnet | Imported, renamed, all settings matched to reality |

**Entire dev environment is now under Terraform management** — every resource that started as a hand-built ClickOps artifact is now version-controlled, reproducible, and auditable. Tearing it down (`terraform destroy` from `env/dev`) and re-running `apply` will produce a functionally identical environment with new resource IDs — the blueprint survives even though the specific instances don't.

---

## 9. Open Items / Next Steps

- **`dynamodb_table` deprecation warning** — AWS now supports native S3 locking via `use_lockfile`; current setup still works but is flagged as deprecated on every run.
- **`env/staging/` and `env/prod/`** — not yet built. Same `modules/` are reusable as-is; each new environment needs its own `backend.tf` (same state bucket, different `key`) and `terraform.tfvars` with non-colliding values (bucket names must be globally unique; VPC CIDRs shouldn't overlap if environments need to interconnect).
- **Second subnet** (`us-east-1a`) in the same VPC — not yet imported; nothing currently depends on it.

---

*This log reflects a personal lab environment built for interview preparation. Account IDs, IP addresses, and resource identifiers have been redacted.*