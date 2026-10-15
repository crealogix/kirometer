# Configuration shared by the bootstrap, platform and grafana stacks.
# Each stack links this file (variables.tf -> ../variables.tf), and all values
# come from one file per deployment: config/<environment>.tfvars.
# See config/example.tfvars.

variable "environment" {
  description = "Short name of this deployment, e.g. \"team-a\". Used for local file names and tags."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{0,30}$", var.environment))
    error_message = "Use lowercase letters, digits and dashes."
  }
}

# --- AWS ---------------------------------------------------------------------

variable "aws_profile" {
  description = "AWS CLI profile to use. null = default credential chain (environment variables, SSO, instance role)."
  type        = string
  default     = null
}

variable "aws_account_id" {
  description = "Account to deploy into. OpenTofu refuses to run against any other account."
  type        = string

  validation {
    condition     = can(regex("^[0-9]{12}$", var.aws_account_id))
    error_message = "An AWS account ID has 12 digits."
  }
}

variable "aws_region" {
  type = string
}

variable "name_prefix" {
  description = "Prefix for all resource names, the state bucket and the state encryption keys."
  type        = string
  default     = "kiro-usage"
}

variable "tags" {
  description = "Extra tags for every resource."
  type        = map(string)
  default     = {}
}

variable "ignore_tag_prefixes" {
  description = "Tag key prefixes managed outside OpenTofu (e.g. by an organization backup automation). OpenTofu leaves them alone."
  type        = list(string)
  default     = []
}

# --- Network -----------------------------------------------------------------

variable "vpc_id" {
  description = "VPC for the database, the ingest Lambda and the Grafana VPC connection."
  type        = string
  default     = null
}

variable "subnet_ids" {
  description = "Private subnets in at least two Availability Zones."
  type        = list(string)
  default     = []
}

variable "interface_endpoint_services" {
  description = "VPC interface endpoints to create. Needed without a NAT gateway; set to [] if the VPC already has them."
  type        = list(string)
  default     = ["secretsmanager", "sns"]
}

# --- Kiro reports ------------------------------------------------------------

variable "source_bucket" {
  description = "S3 bucket Kiro writes its user activity reports to."
  type        = string
  default     = null
}

variable "user_report_paths" {
  description = <<-EOT
    Path(s) to the user_report folder inside source_bucket, as shown in the
    S3 console, e.g. "kiro/AWSLogs/123456789012/KiroLogs/user_report/".
    List more than one if Kiro wrote reports under several prefixes. Nothing
    outside these paths is read; the ingest role has no access to it.
  EOT
  type        = list(string)
  default     = []

  validation {
    condition = alltrue([
      for p in var.user_report_paths : can(regex("^(.*/)?AWSLogs/[0-9]{12}/KiroLogs/user_report/$", p))
    ])
    error_message = "Each path must look like \"<prefix>/AWSLogs/<account-id>/KiroLogs/user_report/\" (with trailing slash)."
  }

  validation {
    condition = length(distinct([
      for p in var.user_report_paths : try(regex("AWSLogs/([0-9]{12})/", p)[0], "")
    ])) <= 1
    error_message = "All user_report paths must belong to the same account."
  }
}

# --- People ------------------------------------------------------------------
# E-mail addresses as registered in IAM Identity Center. Grafana roles are
# resolved to Identity Center user IDs at plan time.

variable "grafana_admin_emails" {
  description = "Grafana Admin: everything, including data source and user management."
  type        = list(string)
  default     = []
}

variable "grafana_editor_emails" {
  description = "Grafana Editor: dashboards, alert rule view and silences."
  type        = list(string)
  default     = []
}

variable "grafana_viewer_emails" {
  description = "Grafana Viewer: dashboards and alert states, read-only."
  type        = list(string)
  default     = []
}

variable "alert_emails" {
  description = "Receive usage alerts (upgrade, overshoot, downgrade). Each address must confirm the SNS subscription."
  type        = list(string)
  default     = []
}

variable "ops_emails" {
  description = "Receive pipeline alerts (ingest errors, schedule not running, stale data)."
  type        = list(string)
  default     = []
}
