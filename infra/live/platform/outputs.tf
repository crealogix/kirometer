output "grafana_workspace_id" {
  value = module.platform.grafana_workspace_id
}

output "grafana_url" {
  value = module.platform.grafana_url
}

output "grafana_service_account_id" {
  value = module.platform.grafana_service_account_id
}

output "db_host" {
  value = module.platform.db_host
}

output "db_port" {
  value = module.platform.db_port
}

output "db_name" {
  value = module.platform.db_name
}

output "reader_role_name" {
  value = module.platform.reader_role_name
}

output "reader_secret_arn" {
  value = module.platform.reader_secret_arn
}

output "alerts_topic_arn" {
  value = module.platform.alerts_topic_arn
}

output "ops_topic_arn" {
  value = module.platform.ops_topic_arn
}

output "ingest_function_name" {
  value = module.platform.ingest_function_name
}
