# Caliber Prod — runbook (Requirement 7 + budget trade-offs for Requirement 5)

## What this provisions (one `terraform apply`)
From `envs/prod` a **single** `terraform apply` creates:
- Remote-state *resources*: S3 bucket + DynamoDB lock table (`module.remote_state`)
- VPC with 2 public + 2 private subnets
- Single NAT Gateway (cost trade-off — **VPC-wide private egress SPOF**, not RDS-only)
- ALB with HTTPS:443 (+ HTTP→HTTPS redirect)
- ECS Fargate mixed capacity: `desired_count=2`, Fargate `base=1` + Fargate Spot `weight=1` (non-root UID 10001, least-privilege IAM)
- RDS PostgreSQL single-AZ `db.t4g.micro` in private subnets (`publicly_accessible = false`), deletion protection on, final snapshot on destroy
- Secrets Manager for DB credentials (`recovery_window_in_days = 7`)
- S3 bucket for static assets (shared `s3-hardened` module)

Chicken-egg: this apply uses a **local** backend because Terraform cannot store state in an S3 bucket created by the same apply. After the first apply, optionally migrate to the bucket that was just created (`backend.hcl.example`). Bootstrap/ is an optional split path, **not** required.

## Prerequisites (configure these FIRST)
1. AWS credentials with rights to create VPC/ECS/RDS/IAM/S3/ACM resources  
   (`AWS_PROFILE` or `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` — never commit keys).
2. An ACM certificate in the **same region** as the ALB (DNS-validated). Copy its ARN.
3. An ECR repository + image that runs as UID/GID **10001** (non-root). See `docker/Dockerfile`.
4. Terraform >= 1.5 (`/data/caliber/.tools/terraform` in this workspace is 1.16.0).

## Bring up prod (clone → configure → init → plan → apply)
```bash
git clone https://github.com/antier700/caliber-iac-prod.git
cd caliber-iac-prod/envs/prod
cp terraform.tfvars.example terraform.tfvars   # fill ACM ARN, image, ECR ARN
terraform init
terraform plan -out=prod.plan
terraform apply prod.plan
# equivalent one-liner after tfvars exist: ../../scripts/provision.sh -auto-approve
```

## Tear down
```bash
cd envs/prod
# deletion_protection=true — disable in a second apply before destroy, or:
terraform apply -var-file=terraform.tfvars -auto-approve \
  -replace=module.database.aws_db_instance.this
# Practical destroy: set deletion_protection=false in a PR, apply, then:
terraform destroy
```

## Optional: migrate state to S3 after first apply
```bash
# fill bucket + dynamodb_table from terraform output remote_state_bucket / remote_state_lock_table
cp backend.hcl.example backend.hcl
terraform init -migrate-state -backend-config=backend.hcl
```

## Budget cap: $150 / month (implemented HCL trade-offs)
Approximate us-east-1 list prices (steady-state, low traffic):

| Item | Choice | ~USD/mo |
|------|--------|---------|
| NAT | **1×** NAT Gateway (not 2) | ~32 |
| ALB | 1 ALB light traffic | ~16–22 |
| ECS | Fargate 0.25 vCPU / 0.5 GB ×1 on-demand + ×1 Spot | ~8–14 |
| RDS | **single-AZ** `db.t4g.micro` 20 GB gp3 | ~12–15 |
| S3 / Secrets / CW logs / DynamoDB lock | light | ~3–6 |
| **Total** | | **~$71–89** |

Deliberately **not** chosen: Multi-AZ RDS (~2× DB, often >$150 with NAT+ALB), NAT per AZ (~2× NAT), all-on-demand Fargate, Container Insights.

### Failure modes (numeric RTO/RPO) — do not conflate them

**1. RDS AZ failure (single-AZ instance)**
- **RPO:** last automated backup / PITR (retention **7 days**; continuous PITR inside that window).
- **RTO:** restore a new single-AZ instance from snapshot into a healthy AZ ≈ **30–45 min**, then Secrets Manager host update + ECS deploy ≈ **+5–10 min**. Write outage ≈ **35–55 min**.

**2. Single NAT Gateway failure (AZ of `public[0]`)**  
This is **not** an RDS failure mode. RDS in private subnets does not need NAT for serving queries from ECS. NAT is the **only** default route for **all private-subnet egress**: ECS→ECR image pulls, CloudWatch logs if not using VPC endpoints, Debian/apk mirrors, Secrets Manager without an interface endpoint.  
- **RPO:** none (stateless egress).  
- **RTO:** recreate NAT+EIP in a healthy public subnet ≈ **15–30 min**. During that window **new** Fargate tasks cannot pull from ECR; already-running tasks keep serving.

**3. Fargate Spot reclaim**  
`desired_count=2` with Fargate `base=1` keeps one on-demand task. Spot reclaim of the replica: ALB still has a healthy target. **RTO ≈ 0** for the remaining task; replacement Spot ≈ **1–3 min**.

## Verify locally (no AWS account — mock plan-time only)
`terraform test` uses `mock_provider`. Passing tests prove **known-at-plan** invariants, not a live `terraform apply` in AWS.

```bash
export TF_CLI_CONFIG_FILE=/data/caliber/.tools/terraformrc
export PATH="/data/caliber/.tools:$PATH"
./scripts/verify.sh
```
