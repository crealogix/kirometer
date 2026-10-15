locals {
  datasource_uid  = "kiro-usage"
  datasource_type = "grafana-postgresql-datasource"
  dashboards_dir  = coalesce(var.dashboards_dir, "${path.module}/dashboards")
}

resource "grafana_folder" "kiro" {
  uid   = "kiro"
  title = var.folder_title
}

# Uid and type must stay as they are: the dashboard JSON and the alert rules
# reference them. The type must be the registered plugin id; the legacy alias
# "postgres" works for panels but not for alert evaluation.
resource "grafana_data_source" "kiro" {
  uid        = local.datasource_uid
  name       = "kiro-usage"
  type       = local.datasource_type
  url        = "${var.db_host}:${var.db_port}"
  username   = var.db_user
  is_default = true

  json_data_encoded = jsonencode({
    database               = var.db_name
    sslmode                = "verify-full"
    tlsConfigurationMethod = "file-content"
    postgresVersion        = 1800
    timescaledb            = false
    maxOpenConns           = 10
    maxIdleConns           = 5
    connMaxLifetime        = 14400
  })

  secure_json_data_encoded = jsonencode({
    password  = var.db_password
    tlsCACert = var.db_ca_cert
  })
}

resource "grafana_dashboard" "kiro" {
  for_each = fileset(local.dashboards_dir, "*.json")

  folder      = grafana_folder.kiro.uid
  config_json = file("${local.dashboards_dir}/${each.value}")
  overwrite   = true

  depends_on = [grafana_data_source.kiro]
}
