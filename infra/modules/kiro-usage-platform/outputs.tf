output "grafana_workspace_id" {
  value = aws_grafana_workspace.this.id
}

output "grafana_endpoint" {
  description = "Workspace host name, without scheme."
  value       = aws_grafana_workspace.this.endpoint
}

output "grafana_url" {
  value = "https://${aws_grafana_workspace.this.endpoint}"
}

output "grafana_service_account_id" {
  value = aws_grafana_workspace_service_account.opentofu.service_account_id
}

output "db_host" {
  value = aws_db_instance.this.address
}

output "db_port" {
  value = aws_db_instance.this.port
}

output "db_name" {
  value = var.db_name
}

output "reader_role_name" {
  value = var.reader_role_name
}

output "reader_secret_arn" {
  value = aws_secretsmanager_secret.reader.arn
}

output "alerts_topic_arn" {
  value = aws_sns_topic.this["alerts"].arn
}

output "ops_topic_arn" {
  value = aws_sns_topic.this["ops"].arn
}

output "ingest_function_name" {
  value = aws_lambda_function.ingest.function_name
}
