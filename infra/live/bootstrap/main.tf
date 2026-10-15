# Creates the state bucket and the state encryption keys for the platform
# and grafana stacks. Run once per account. Its own state is kept locally in
# config/<environment>.bootstrap.tfstate (bucket and key metadata only, no
# secrets). Back that file up, e.g. by copying it into the state bucket.

terraform {
  required_version = ">= 1.13.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.68"
    }
  }

  backend "local" {
    path = "../../../config/${var.environment}.bootstrap.tfstate"
  }
}

provider "aws" {
  region              = var.aws_region
  profile             = var.aws_profile
  allowed_account_ids = [var.aws_account_id]

  default_tags {
    tags = merge(
      { Project = "kiro-usage-analytics", ManagedBy = "opentofu", Stack = "bootstrap" },
      var.tags,
    )
  }

  ignore_tags {
    key_prefixes = var.ignore_tag_prefixes
  }
}

module "state" {
  source      = "../../modules/state-bootstrap"
  name_prefix = var.name_prefix
}

output "state_bucket" {
  value = module.state.state_bucket
}

output "kms_key_aliases" {
  value = module.state.kms_key_aliases
}
