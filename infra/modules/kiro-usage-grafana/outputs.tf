output "folder_uid" {
  value = grafana_folder.kiro.uid
}

output "dashboard_urls" {
  value = { for k, d in grafana_dashboard.kiro : k => d.url }
}

output "rule_uids" {
  value = [for r in local.rules : r.uid]
}
