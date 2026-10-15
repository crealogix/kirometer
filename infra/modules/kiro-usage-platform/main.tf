data "aws_caller_identity" "current" {}
data "aws_region" "current" {}
data "aws_partition" "current" {}

data "aws_subnet" "selected" {
  for_each = toset(var.subnet_ids)
  id       = each.value
}

locals {
  account_id = data.aws_caller_identity.current.account_id
  region     = data.aws_region.current.region
  partition  = data.aws_partition.current.partition

  source_account_id = coalesce(var.source_account_id, local.account_id)
  source_regions    = coalesce(var.source_regions, [local.region])

  # Exactly the user_report reports. The bucket also holds prompt and
  # completion logs; nothing here grants access to them.
  user_report_prefixes = [
    for p in var.source_prefixes : "${p}AWSLogs/${local.source_account_id}/KiroLogs/user_report/"
  ]

  subnet_azs                 = distinct([for s in data.aws_subnet.selected : s.availability_zone])
  endpoint_subnet_ids        = coalesce(var.interface_endpoint_subnet_ids, slice(var.subnet_ids, 0, 1))
  create_endpoints           = length(var.interface_endpoint_services) > 0
  pg_major                   = split(".", var.db_engine_version)[0]
  ingest_function_name       = "${var.name_prefix}-ingest"
  grafana_workspace_arn_glob = "arn:${local.partition}:grafana:${local.region}:${local.account_id}:/workspaces/*"
}
