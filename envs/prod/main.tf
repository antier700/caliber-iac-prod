terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.100"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.9"
    }
  }

  # Local backend so the first (and only required) `terraform apply` creates
  # VPC + ECS + RDS + assets + the S3/DynamoDB remote-state resources together.
  # You cannot store this apply's state in a bucket created by the same apply.
  # After first apply, optionally: terraform init -migrate-state -backend-config=backend.hcl
  backend "local" {
    path = "terraform.tfstate"
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = local.tags
  }
}

locals {
  name_prefix = var.name_prefix
  tags = {
    Project     = var.name_prefix
    Environment = "prod"
    ManagedBy   = "terraform"
    CostCapUSD  = "150"
  }
}

module "remote_state" {
  source      = "../../modules/state-bootstrap"
  name_prefix = local.name_prefix
  tags        = merge(local.tags, { Purpose = "remote-state" })
}

module "networking" {
  source      = "../../modules/networking"
  name_prefix = local.name_prefix
  vpc_cidr    = var.vpc_cidr
  tags        = local.tags
}

module "assets" {
  source      = "../../modules/assets"
  name_prefix = local.name_prefix
  tags        = local.tags
}

module "database" {
  source                      = "../../modules/database"
  name_prefix                 = local.name_prefix
  vpc_id                      = module.networking.vpc_id
  vpc_cidr                    = var.vpc_cidr
  private_subnet_ids          = module.networking.private_subnet_ids
  ecs_tasks_security_group_id = module.networking.ecs_tasks_security_group_id
  instance_class              = "db.t4g.micro"
  tags                        = local.tags
}

module "compute" {
  source                      = "../../modules/compute"
  name_prefix                 = local.name_prefix
  vpc_id                      = module.networking.vpc_id
  public_subnet_ids           = module.networking.public_subnet_ids
  private_subnet_ids          = module.networking.private_subnet_ids
  ecs_tasks_security_group_id = module.networking.ecs_tasks_security_group_id
  acm_certificate_arn         = var.acm_certificate_arn
  container_image             = var.container_image
  ecr_repository_arn          = var.ecr_repository_arn
  db_secret_arn               = module.database.db_secret_arn
  assets_bucket_arn           = module.assets.bucket_arn
  assets_bucket_id            = module.assets.bucket_id
  task_cpu                    = "256"
  task_memory                 = "512"
  desired_count               = 2
  tags                        = local.tags
}
