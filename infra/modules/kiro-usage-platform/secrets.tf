# Password of the read-only database role Grafana uses. Generated as an
# ephemeral value and written with a write-only attribute, so it is never
# stored in this stack's state. The ingest function reads it and sets the
# role password; the grafana stack reads it for the data source.

resource "aws_secretsmanager_secret" "reader" {
  name                    = "${var.name_prefix}/grafana-reader"
  description             = "Password of the ${var.reader_role_name} PostgreSQL role"
  kms_key_id              = aws_kms_key.this.arn
  recovery_window_in_days = 7
}

ephemeral "aws_secretsmanager_random_password" "reader" {
  password_length     = 40
  exclude_punctuation = true
}

resource "aws_secretsmanager_secret_version" "reader" {
  secret_id                = aws_secretsmanager_secret.reader.id
  secret_string_wo         = ephemeral.aws_secretsmanager_random_password.reader.random_password
  secret_string_wo_version = var.reader_password_version
}
