data "aws_ec2_managed_prefix_list" "s3" {
  name = "com.amazonaws.${local.region}.s3"
}

# The provider removes AWS's default allow-all egress rule from these groups,
# so every permitted flow is listed below.

resource "aws_security_group" "ingest" {
  name        = "${var.name_prefix}-ingest"
  description = "Kiro ingest Lambda"
  vpc_id      = var.vpc_id
}

resource "aws_security_group" "db" {
  name        = "${var.name_prefix}-db"
  description = "Kiro usage PostgreSQL"
  vpc_id      = var.vpc_id
}

resource "aws_security_group" "grafana" {
  name        = "${var.name_prefix}-grafana"
  description = "Managed Grafana VPC connection"
  vpc_id      = var.vpc_id
}

resource "aws_security_group" "endpoints" {
  count = local.create_endpoints ? 1 : 0

  name        = "${var.name_prefix}-endpoints"
  description = "Interface endpoints used by the Kiro ingest and Grafana"
  vpc_id      = var.vpc_id
}

# --- Database access -------------------------------------------------------

resource "aws_vpc_security_group_ingress_rule" "db_from_ingest" {
  security_group_id            = aws_security_group.db.id
  referenced_security_group_id = aws_security_group.ingest.id
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
  description                  = "Ingest Lambda"
}

resource "aws_vpc_security_group_ingress_rule" "db_from_grafana" {
  security_group_id            = aws_security_group.db.id
  referenced_security_group_id = aws_security_group.grafana.id
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
  description                  = "Managed Grafana"
}

resource "aws_vpc_security_group_egress_rule" "ingest_to_db" {
  security_group_id            = aws_security_group.ingest.id
  referenced_security_group_id = aws_security_group.db.id
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
  description                  = "PostgreSQL"
}

resource "aws_vpc_security_group_egress_rule" "grafana_to_db" {
  security_group_id            = aws_security_group.grafana.id
  referenced_security_group_id = aws_security_group.db.id
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
  description                  = "PostgreSQL"
}

# --- AWS APIs --------------------------------------------------------------

resource "aws_vpc_security_group_egress_rule" "ingest_to_s3" {
  security_group_id = aws_security_group.ingest.id
  prefix_list_id    = data.aws_ec2_managed_prefix_list.s3.id
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  description       = "S3 through the gateway endpoint"
}

resource "aws_vpc_security_group_egress_rule" "ingest_to_endpoints" {
  count = local.create_endpoints ? 1 : 0

  security_group_id            = aws_security_group.ingest.id
  referenced_security_group_id = aws_security_group.endpoints[0].id
  ip_protocol                  = "tcp"
  from_port                    = 443
  to_port                      = 443
  description                  = "Interface endpoints"
}

resource "aws_vpc_security_group_egress_rule" "grafana_to_endpoints" {
  count = local.create_endpoints ? 1 : 0

  security_group_id            = aws_security_group.grafana.id
  referenced_security_group_id = aws_security_group.endpoints[0].id
  ip_protocol                  = "tcp"
  from_port                    = 443
  to_port                      = 443
  description                  = "Interface endpoints"
}

resource "aws_vpc_security_group_ingress_rule" "endpoints_from_ingest" {
  count = local.create_endpoints ? 1 : 0

  security_group_id            = aws_security_group.endpoints[0].id
  referenced_security_group_id = aws_security_group.ingest.id
  ip_protocol                  = "tcp"
  from_port                    = 443
  to_port                      = 443
  description                  = "Ingest Lambda"
}

resource "aws_vpc_security_group_ingress_rule" "endpoints_from_grafana" {
  count = local.create_endpoints ? 1 : 0

  security_group_id            = aws_security_group.endpoints[0].id
  referenced_security_group_id = aws_security_group.grafana.id
  ip_protocol                  = "tcp"
  from_port                    = 443
  to_port                      = 443
  description                  = "Managed Grafana"
}

resource "aws_vpc_security_group_egress_rule" "ingest_extra_https" {
  for_each = toset(var.extra_https_egress_cidrs)

  security_group_id = aws_security_group.ingest.id
  cidr_ipv4         = each.value
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  description       = "HTTPS (extra)"
}

resource "aws_vpc_security_group_egress_rule" "grafana_extra_https" {
  for_each = toset(var.extra_https_egress_cidrs)

  security_group_id = aws_security_group.grafana.id
  cidr_ipv4         = each.value
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  description       = "HTTPS (extra)"
}

# --- Interface endpoints ---------------------------------------------------

# With private DNS these endpoints serve every client in the VPC, so the
# policy is limited to this account rather than to this project's resources.
data "aws_iam_policy_document" "endpoint" {
  statement {
    sid       = "ThisAccountOnly"
    actions   = ["*"]
    resources = ["*"]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:PrincipalAccount"
      values   = [local.account_id]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:ResourceAccount"
      values   = [local.account_id]
    }
  }
}

resource "aws_vpc_endpoint" "interface" {
  for_each = toset(var.interface_endpoint_services)

  vpc_id              = var.vpc_id
  service_name        = "com.amazonaws.${local.region}.${each.value}"
  vpc_endpoint_type   = "Interface"
  private_dns_enabled = true
  subnet_ids          = local.endpoint_subnet_ids
  security_group_ids  = [aws_security_group.endpoints[0].id]
  policy              = data.aws_iam_policy_document.endpoint.json

  tags = {
    Name = "${var.name_prefix}-${each.value}"
  }
}
