variable "db_host" {
  type = string
}

variable "db_port" {
  type    = number
  default = 5432
}

variable "db_name" {
  type = string
}

variable "db_user" {
  description = "Read-only reporting role."
  type        = string
}

variable "db_password" {
  type      = string
  sensitive = true
}

variable "db_ca_cert" {
  description = "PEM bundle used to verify the database certificate (sslmode verify-full)."
  type        = string
}

variable "alerts_topic_arn" {
  description = "SNS topic for usage alerts."
  type        = string
}

variable "ops_topic_arn" {
  description = "SNS topic for pipeline alerts."
  type        = string
}

variable "folder_title" {
  type    = string
  default = "Kiro"
}

variable "dashboards_dir" {
  description = "Directory with dashboard JSON files. Default: the dashboards shipped with this module."
  type        = string
  default     = null
}

variable "evaluation_interval_seconds" {
  description = "How often alert rules are evaluated. Grafana picks its own offset within the interval, so this must be short enough that rules re-evaluate between the ingest (06:30 UTC) and the delivery window (07:00 UTC)."
  type        = number
  default     = 600
}

variable "report_windows" {
  description = "Times of day when usage alerts may be sent."
  type = list(object({
    start = string
    end   = string
  }))
  default = [
    { start = "07:00", end = "07:15" },
  ]
}

variable "report_days_of_month" {
  description = "Days of the month when usage alerts may be sent. The 28th exists in every month, so the default reports once a month, every month."
  type        = list(string)
  default     = ["28"]
}

variable "report_windows_timezone" {
  type    = string
  default = "UTC"
}

variable "usage_repeat_interval" {
  description = "Repeat interval for still-firing usage alerts. Must be shorter than the gap between two report days (28 days from Feb 28 to Mar 28) so each report day repeats them. Written the way Grafana stores it (27d), otherwise every plan shows a change."
  type        = string
  default     = "27d"
}

variable "freshness_max_days_behind" {
  description = "Pipeline alert when the newest imported report is older than this many days. 1 is normal."
  type        = number
  default     = 2
}
