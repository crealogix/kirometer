data "aws_iam_policy_document" "grafana_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["grafana.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
    condition {
      test     = "StringLike"
      variable = "aws:SourceArn"
      values   = [local.grafana_workspace_arn_glob]
    }
  }
}

resource "aws_iam_role" "grafana" {
  name               = "${var.name_prefix}-grafana"
  assume_role_policy = data.aws_iam_policy_document.grafana_assume.json
}

# The workspace only needs to publish alerts. The database is reached with
# its own read-only credentials, not through IAM.
data "aws_iam_policy_document" "grafana" {
  statement {
    sid       = "PublishAlerts"
    actions   = ["sns:Publish"]
    resources = [for t in aws_sns_topic.this : t.arn]
  }

  statement {
    sid       = "EncryptedTopics"
    actions   = ["kms:GenerateDataKey*", "kms:Decrypt"]
    resources = [aws_kms_key.this.arn]
    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["sns.${local.region}.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy" "grafana" {
  name   = "publish-alerts"
  role   = aws_iam_role.grafana.id
  policy = data.aws_iam_policy_document.grafana.json
}

resource "aws_grafana_workspace" "this" {
  name                      = var.name_prefix
  description               = "Kiro credit usage dashboards and alerts"
  grafana_version           = var.grafana_version
  account_access_type       = "CURRENT_ACCOUNT"
  authentication_providers  = ["AWS_SSO"]
  permission_type           = "CUSTOMER_MANAGED"
  role_arn                  = aws_iam_role.grafana.arn
  notification_destinations = ["SNS"]

  # All workspace traffic, including alert delivery, then flows through the VPC.
  vpc_configuration {
    subnet_ids         = var.subnet_ids
    security_group_ids = [aws_security_group.grafana.id]
  }

  lifecycle {
    precondition {
      condition     = length(local.subnet_azs) >= 2
      error_message = "Managed Grafana needs subnets in at least two Availability Zones."
    }
  }

  depends_on = [aws_iam_role_policy.grafana]
}

resource "aws_grafana_role_association" "admin" {
  count = length(var.grafana_admin_user_ids) + length(var.grafana_admin_group_ids) > 0 ? 1 : 0

  workspace_id = aws_grafana_workspace.this.id
  role         = "ADMIN"
  user_ids     = length(var.grafana_admin_user_ids) > 0 ? var.grafana_admin_user_ids : null
  group_ids    = length(var.grafana_admin_group_ids) > 0 ? var.grafana_admin_group_ids : null
}

resource "aws_grafana_role_association" "editor" {
  count = length(var.grafana_editor_user_ids) + length(var.grafana_editor_group_ids) > 0 ? 1 : 0

  workspace_id = aws_grafana_workspace.this.id
  role         = "EDITOR"
  user_ids     = length(var.grafana_editor_user_ids) > 0 ? var.grafana_editor_user_ids : null
  group_ids    = length(var.grafana_editor_group_ids) > 0 ? var.grafana_editor_group_ids : null
}

resource "aws_grafana_role_association" "viewer" {
  count = length(var.grafana_viewer_user_ids) + length(var.grafana_viewer_group_ids) > 0 ? 1 : 0

  workspace_id = aws_grafana_workspace.this.id
  role         = "VIEWER"
  user_ids     = length(var.grafana_viewer_user_ids) > 0 ? var.grafana_viewer_user_ids : null
  group_ids    = length(var.grafana_viewer_group_ids) > 0 ? var.grafana_viewer_group_ids : null
}

# Used by the grafana stack. Its tokens are minted per run with a one-hour
# lifetime (scripts/with-grafana-token.sh) and never stored in state.
resource "aws_grafana_workspace_service_account" "opentofu" {
  workspace_id = aws_grafana_workspace.this.id
  name         = "opentofu"
  grafana_role = "ADMIN"
}
