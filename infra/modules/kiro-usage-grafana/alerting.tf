# Each rule's query returns one row per user (or account). Grafana turns the
# string columns into labels, so every row becomes its own alert instance,
# and the numeric `value` column is compared against 0 (or the threshold).

locals {
  rules = {
    upgrade = {
      uid         = "kiro-tier-upgrade"
      title       = "Kiro - next subscription tier would be cheaper"
      threshold   = 0
      sql         = <<-SQL
        SELECT user_label, account_id, subscription_tier, next_tier,
               monthly_saving_usd AS value
        FROM v_alert_tier_upgrade
        ORDER BY monthly_saving_usd DESC
      SQL
      labels      = { severity = "warning", team = "finops", alert_type = "tier_upgrade" }
      summary     = "{{ $labels.user_label }} is on {{ $labels.subscription_tier }} but {{ $labels.next_tier }} would be cheaper this month (saving $${{ printf \"%.2f\" $values.B.Value }})."
      description = "Month-to-date credit consumption has passed the break-even point for the current tier. Switching to {{ $labels.next_tier }} lowers the monthly cost at the same consumption. Talk to the user before changing anything."
    }

    forecast = {
      uid         = "kiro-overage-forecast"
      title       = "Kiro - forecast month-end credit overshoot"
      threshold   = 0
      sql         = <<-SQL
        SELECT user_label, account_id, subscription_tier,
               overshoot_vs_threshold AS value
        FROM v_alert_overage_forecast
        ORDER BY overshoot_vs_threshold DESC
      SQL
      labels      = { severity = "warning", team = "finops", alert_type = "overage_forecast" }
      summary     = "{{ $labels.user_label }} ({{ $labels.subscription_tier }}) is projected to end the month {{ printf \"%.0f\" $values.B.Value }} credits past the point where upgrading would have been cheaper."
      description = "Projection = month-to-date credits plus the average daily consumption of the last 7 days over the remaining days of the month. Thresholds: 500 credits on PRO, 1500 on PRO_PLUS, 2500 on PRO_MAX (next tier cheaper), 5000 on POWER (a second seat cheaper). The data is an indicator only; talk to the user first."
    }

    downgrade = {
      uid         = "kiro-tier-downgrade"
      title       = "Kiro - downgrade candidate"
      threshold   = 0
      sql         = <<-SQL
        SELECT user_label, account_id, subscription_tier, recommended_tier, evidence,
               monthly_saving_usd AS value
        FROM v_alert_tier_downgrade
        ORDER BY monthly_saving_usd DESC
      SQL
      labels      = { severity = "info", team = "finops", alert_type = "tier_downgrade" }
      summary     = "{{ $labels.user_label }} on {{ $labels.subscription_tier }} is a downgrade candidate: {{ $labels.recommended_tier }} would save $${{ printf \"%.2f\" $values.B.Value }} per month."
      description = "A cheaper tier would have covered both the previous calendar month and the projection for this month (evidence: {{ $labels.evidence }}). Absence, tool evaluations and one-off quiet months look the same in the data; ask the user before changing the subscription."
    }

    freshness = {
      uid         = "kiro-data-freshness"
      title       = "Kiro - usage data is stale"
      threshold   = var.freshness_max_days_behind
      sql         = <<-SQL
        SELECT account_id, days_behind AS value
        FROM v_data_freshness
      SQL
      labels      = { severity = "warning", team = "ops", alert_type = "data_freshness" }
      summary     = "Kiro usage data for account {{ $labels.account_id }} is {{ printf \"%.0f\" $values.B.Value }} days behind."
      description = "Kiro writes each day's report at 02:00 UTC the next day, so 1 day behind is normal. Check the ingest function log and the source bucket."
    }
  }
}

resource "grafana_rule_group" "kiro" {
  name             = "kiro-credit-alerts"
  folder_uid       = grafana_folder.kiro.uid
  interval_seconds = var.evaluation_interval_seconds

  dynamic "rule" {
    for_each = local.rules
    content {
      uid            = rule.value.uid
      name           = rule.value.title
      condition      = "C"
      for            = "0s"
      no_data_state  = "OK"
      exec_err_state = "Error"
      labels         = rule.value.labels
      annotations = {
        summary     = rule.value.summary
        description = rule.value.description
      }

      data {
        ref_id         = "A"
        datasource_uid = grafana_data_source.kiro.uid
        # Must be non-zero although the views scope themselves to the month.
        relative_time_range {
          from = 600
          to   = 0
        }
        model = jsonencode({
          refId         = "A"
          datasource    = { type = local.datasource_type, uid = grafana_data_source.kiro.uid }
          format        = "table"
          rawQuery      = true
          editorMode    = "code"
          rawSql        = rule.value.sql
          intervalMs    = 1000
          maxDataPoints = 43200
        })
      }

      data {
        ref_id         = "B"
        datasource_uid = "__expr__"
        relative_time_range {
          from = 0
          to   = 0
        }
        model = jsonencode({
          refId      = "B"
          type       = "reduce"
          expression = "A"
          reducer    = "last"
          datasource = { type = "__expr__", uid = "__expr__" }
        })
      }

      data {
        ref_id         = "C"
        datasource_uid = "__expr__"
        relative_time_range {
          from = 0
          to   = 0
        }
        model = jsonencode({
          refId      = "C"
          type       = "threshold"
          expression = "B"
          datasource = { type = "__expr__", uid = "__expr__" }
          conditions = [{ evaluator = { type = "gt", params = [rule.value.threshold] } }]
        })
      }
    }
  }
}

# --- Delivery --------------------------------------------------------------

resource "grafana_contact_point" "finops" {
  name = "kiro-finops"
  sns {
    topic = var.alerts_topic_arn
    # Grafana 13's SNS integration reads `topic_arn`; provider 4.49 only
    # sends `topic`, which Grafana 13 rejects. With no sigv4 block, Grafana
    # signs with the workspace IAM role.
    settings = { topic_arn = var.alerts_topic_arn }
  }
}

resource "grafana_contact_point" "ops" {
  name = "kiro-ops"
  sns {
    topic    = var.ops_topic_arn
    settings = { topic_arn = var.ops_topic_arn }
  }
}

# Rules are evaluated on an interval, not on a clock schedule, so usage
# alerts are held back and only delivered inside this window: by default
# 07:00-07:15 UTC on the 28th of every month.
resource "grafana_mute_timing" "report_windows" {
  name = "kiro-report-windows"
  intervals {
    location      = var.report_windows_timezone
    days_of_month = var.report_days_of_month
    dynamic "times" {
      for_each = var.report_windows
      content {
        start = times.value.start
        end   = times.value.end
      }
    }
  }
}

# Replaces the workspace's root notification policy.
resource "grafana_notification_policy" "root" {
  contact_point = grafana_contact_point.finops.name
  group_by      = ["alertname", "user_label"]

  # Usage alerts (upgrade, overshoot, downgrade): only on the report day.
  policy {
    contact_point = grafana_contact_point.finops.name
    matcher {
      label = "team"
      match = "="
      value = "finops"
    }
    active_timings  = [grafana_mute_timing.report_windows.name]
    group_wait      = "1m"
    group_interval  = "5m" # shorter than the window, so a flush always lands inside it
    repeat_interval = var.usage_repeat_interval
  }

  # Pipeline alerts: whenever they happen.
  policy {
    contact_point = grafana_contact_point.ops.name
    matcher {
      label = "team"
      match = "="
      value = "ops"
    }
    group_by        = ["alertname", "account_id"]
    repeat_interval = "12h"
  }
}
