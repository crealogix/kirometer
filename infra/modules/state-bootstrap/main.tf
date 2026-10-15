terraform {
  required_version = ">= 1.13.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.68"
    }
  }
}

variable "name_prefix" {
  description = "Prefix for resource names, e.g. kiro-usage."
  type        = string
}

variable "stacks" {
  description = "State files that get their own KMS key for client-side state encryption."
  type        = set(string)
  default     = ["platform", "grafana"]
}

variable "noncurrent_version_retention_days" {
  description = "How long old state versions are kept for recovery."
  type        = number
  default     = 90
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  bucket_name = "${var.name_prefix}-tofu-state-${data.aws_caller_identity.current.account_id}-${data.aws_region.current.region}"
}

# One key per state file, as OpenTofu recommends: states stay cryptographically
# isolated and access can be scoped per stack.
resource "aws_kms_key" "state" {
  for_each = var.stacks

  description             = "OpenTofu state encryption: ${var.name_prefix}/${each.key}"
  enable_key_rotation     = true
  deletion_window_in_days = 30
}

resource "aws_kms_alias" "state" {
  for_each = var.stacks

  name          = "alias/${var.name_prefix}-tofu-${each.key}"
  target_key_id = aws_kms_key.state[each.key].key_id
}

resource "aws_s3_bucket" "state" {
  bucket = local.bucket_name

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket                  = aws_s3_bucket.state.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "state" {
  bucket = aws_s3_bucket.state.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id
  versioning_configuration {
    status = "Enabled"
  }
}

# State content is already encrypted client-side with KMS; bucket encryption
# is the second layer.
resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    id     = "expire-old-state-versions"
    status = "Enabled"
    filter {}
    noncurrent_version_expiration {
      noncurrent_days = var.noncurrent_version_retention_days
    }
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

data "aws_iam_policy_document" "state" {
  statement {
    sid     = "DenyInsecureTransport"
    effect  = "Deny"
    actions = ["s3:*"]
    resources = [
      aws_s3_bucket.state.arn,
      "${aws_s3_bucket.state.arn}/*",
    ]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "state" {
  bucket = aws_s3_bucket.state.id
  policy = data.aws_iam_policy_document.state.json

  depends_on = [aws_s3_bucket_public_access_block.state]
}

output "state_bucket" {
  value = aws_s3_bucket.state.id
}

output "kms_key_aliases" {
  description = "Alias per stack, for the encryption block of each stack."
  value       = { for k, a in aws_kms_alias.state : k => a.name }
}

output "region" {
  value = data.aws_region.current.region
}
