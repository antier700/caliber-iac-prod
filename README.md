# iac-prod

Terraform modules for a budget-capped AWS production environment (Caliber L2 Build Sprint).

See **RUNBOOK.md** for clone → configure → single `terraform apply` → destroy and the $150/mo trade-offs.

## Layout
- `modules/s3-hardened` — versioned, encrypted, public-access-blocked bucket (shared)
- `modules/networking` — VPC, public/private subnets, single NAT, ECS identity SG
- `modules/compute` — HTTPS ALB, mixed Fargate/Spot, compute-owned ALB→task SG, least-privilege IAM, non-root task
- `modules/database` — private single-AZ RDS Postgres + Secrets Manager
- `modules/assets` — thin wrapper around `s3-hardened`
- `modules/state-bootstrap` — S3 state bucket + DynamoDB lock (`s3-hardened` + table)
- `envs/prod/` — **canonical** environment: one `terraform apply` (local backend + remote-state *resources*)
- `bootstrap/` — optional split path only; not required
