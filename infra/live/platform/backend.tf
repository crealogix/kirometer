# Backend and encryption settings use variables (OpenTofu early evaluation),
# so they must be available at init: run through the Makefile, which passes
# config/<environment>.tfvars to every tofu command.

terraform {
  required_version = ">= 1.13.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.68"
    }
  }

  backend "s3" {
    bucket       = "${var.name_prefix}-tofu-state-${var.aws_account_id}-${var.aws_region}"
    key          = "platform/terraform.tfstate"
    region       = var.aws_region
    profile      = var.aws_profile
    use_lockfile = true
    encrypt      = true
  }

  # Client-side encryption of state and plan files with this stack's own key.
  encryption {
    key_provider "aws_kms" "platform" {
      kms_key_id = "alias/${var.name_prefix}-tofu-platform"
      region     = var.aws_region
      profile    = var.aws_profile
      key_spec   = "AES_256"
      # Label inside the encrypted file; must be a literal and must not change.
      encrypted_metadata_alias = "kiro-usage-platform"
    }
    method "aes_gcm" "platform" {
      keys = key_provider.aws_kms.platform
    }
    state {
      method   = method.aes_gcm.platform
      enforced = true
    }
    plan {
      method   = method.aes_gcm.platform
      enforced = true
    }
  }
}
