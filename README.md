# import-project

# AWS ClickOps-to-Terraform Migration

![Terraform](https://img.shields.io/badge/Terraform-%235835CC.svg?style=for-the-badge&logo=terraform&logoColor=white)
![AWS](https://img.shields.io/badge/AWS-%23FF9900.svg?style=for-the-badge&logo=amazon-aws&logoColor=white)
![Bash](https://img.shields.io/badge/Bash-4EAA25?style=for-the-badge&logo=gnu-bash&logoColor=white)
![Status](https://img.shields.io/badge/status-active-brightgreen?style=for-the-badge)
![Environments](https://img.shields.io/badge/environments-dev%20%7C%20staging-blue?style=for-the-badge)
![License](https://img.shields.io/badge/license-personal%20lab-lightgrey?style=for-the-badge)

A hands-on migration of a hand-built ("ClickOps") AWS environment into fully modular, reusable Terraform — built to demonstrate the real workflow behind modernizing infrastructure that grew organically, not from a clean slate.

---

## What this is

This repo tells a before/after story:

1. A small AWS environment was **deliberately built by hand** in the console — an untagged VPC, an open security group, an unencrypted S3 bucket, an IAM user with `AdministratorAccess` — reproducing the kind of organic sprawl that shows up in fast-growing teams.
2. That environment was then **migrated into Terraform** using `terraform import`, module by module, reconciling code to match reality before making any changes.
3. Once under management, each piece was **hardened**: least-privilege IAM replacing the admin user, encryption/versioning/public-access-blocking on S3, SSH locked down to a single IP, a proper VPC/IGW/route table built out.
4. The result is a set of **reusable modules** — proven by standing up a second, fully independent `staging` environment from the same code with zero manual steps.

---

## Architecture

```
project/
├── bootstrap/              # One-time setup: Terraform's own remote state backend
│   ├── main.tf              # S3 bucket + DynamoDB lock table, local state only
│   ├── variables.tf
│   ├── outputs.tf
│   └── terraform.tfvars
│
├── modules/                # Reusable blueprints — no environment-specific values
│   ├── network/              # VPC, subnet, security group, IGW, route table
│   ├── storage/               # S3 bucket + encryption/versioning/public-access-block
│   ├── iam/                    # Least-privilege role + instance profile
│   └── compute/                 # EC2 instance, latest-AMI lookup, externalized user_data
│
└── env/
    ├── dev/                 # First environment — imported from ClickOps
    │   ├── main.tf
    │   ├── backend.tf
    │   ├── variables.tf
    │   ├── outputs.tf
    │   └── terraform.tfvars
    └── staging/               # Second environment — built from scratch, zero imports
        └── (same structure)
```

---

## The pain points this fixes

| Before (ClickOps) | After (Terraform) |
|---|---|
| Untagged, unencrypted, versionless S3 bucket, public access allowed | Tagged, SSE-encrypted, versioned, public access blocked — module default |
| IAM user with `AdministratorAccess` attached directly to the app | Least-privilege IAM role + instance profile, scoped to one bucket |
| EC2 instance with an unpinned AMI and startup script only in a console field | Startup script version-controlled as its own file; AMI dynamically resolved to the latest official image |
| Security group open to `0.0.0.0/0` on port 22 | SSH restricted to a single admin IP, applied as an auditable code change |
| VPC/subnet with no naming convention, no outbound route | VPC, subnet, Internet Gateway, and route table fully managed, tagged, and wired together |
| One environment, rebuilt by hand each time | Two independent environments (`dev`, `staging`) from the same module set, zero copy-paste drift |

---

## Key engineering decisions

- **Import before improve.** Every existing resource was matched to code *exactly* first — confirming a zero-diff `plan` — before any hardening was applied. This avoids noisy, hard-to-review diffs and proves intent at every step.
- **Modules take no hardcoded values.** Every module is driven entirely by variables, so the same code produces `dev` or `staging` — or eventually `prod` — purely based on what `terraform.tfvars` supplies.
- **Explicit dependency management.** A `depends_on` was added where implicit resource references weren't enough to guarantee build order (e.g., ensuring the network path exists before an instance boots and tries to reach the internet).
- **A full teardown-and-rebuild was used as a real test.** `terraform import` can mask bugs in a module's code, since import adopts a resource's existing state rather than validating that the code alone could produce it. Two real bugs (a missing `vpc_id` on the security group, a missing boot-order dependency) only surfaced once the environment was destroyed and rebuilt from nothing — which is exactly why that test matters.

---

## Getting started

```bash
# 1. Bootstrap the remote state backend (once, ever)
cd bootstrap
terraform init
terraform apply

# 2. Stand up an environment
cd ../env/dev
terraform init
terraform plan
terraform apply
```

Standing up a new environment (e.g. `staging`) requires no changes to `modules/` — only a new `env/<name>/` folder with its own `backend.tf` (same state bucket, unique `key`) and `terraform.tfvars` (non-colliding bucket name and VPC CIDR).

---

## Roadmap

- [x] Bootstrap remote state (S3 + DynamoDB)
- [x] Import and harden storage, IAM, compute, and network from ClickOps
- [x] Prove module reusability with a second environment (`staging`)
- [ ] Migrate bootstrap's own state under Terraform management
- [ ] Stand up `prod` as a genuine production deployment
- [ ] CI/CD rollout: Jenkins → Azure DevOps → GitHub Actions → GitLab, in that order
- [ ] OIDC-based authentication for every pipeline — no long-lived AWS credentials stored anywhere
- [ ] Security scanning gates: Snyk, Gitleaks, TruffleHog, tfsec, Checkov
- [ ] v2: a fully private redesign, no public subnet or internet-facing compute
