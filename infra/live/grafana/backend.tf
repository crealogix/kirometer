terraform {
  required_version = ">= 1.13.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.68"
    }
    grafana = {
      source  = "grafana/grafana"
      version = "~> 4.49"
    }
  }

  backend "s3" {
    bucket       = "${var.name_prefix}-tofu-state-${var.aws_account_id}-${var.aws_region}"
    key          = "grafana/terraform.tfstate"
    region       = var.aws_region
    profile      = var.aws_profile
    use_lockfile = true
    encrypt      = true
  }

  # This state holds the Grafana database password (the Grafana provider has
  # no write-only attribute for data source secrets), so it is encrypted with
  # its own key. The platform key is only used to read the platform outputs.
  encryption {
    key_provider "aws_kms" "grafana" {
      kms_key_id = "alias/${var.name_prefix}-tofu-grafana"
      region     = var.aws_region
      profile    = var.aws_profile
      key_spec   = "AES_256"
      # Label inside the encrypted file; must be a literal and must not change.
      encrypted_metadata_alias = "kiro-usage-grafana"
    }
    key_provider "aws_kms" "platform" {
      kms_key_id = "alias/${var.name_prefix}-tofu-platform"
      region     = var.aws_region
      profile    = var.aws_profile
      key_spec   = "AES_256"
      # Label inside the encrypted file; must be a literal and must not change.
      encrypted_metadata_alias = "kiro-usage-platform"
    }
    method "aes_gcm" "grafana" {
      keys = key_provider.aws_kms.grafana
    }
    method "aes_gcm" "platform" {
      keys = key_provider.aws_kms.platform
    }
    state {
      method   = method.aes_gcm.grafana
      enforced = true
    }
    plan {
      method   = method.aes_gcm.grafana
      enforced = true
    }
    remote_state_data_sources {
      remote_state_data_source "platform" {
        method = method.aes_gcm.platform
      }
    }
  }
}
