resource "random_password" "db" {
  length  = 20
  special = false
}

resource "aws_secretsmanager_secret" "db" {
  name                    = "${local.name_prefix}-db-password"
  description             = "Master password for the ${local.name_prefix} PostgreSQL database"
  recovery_window_in_days = 0 # throwaway env: allow immediate re-create after destroy
  tags                    = local.common_tags
}

resource "aws_secretsmanager_secret_version" "db" {
  secret_id     = aws_secretsmanager_secret.db.id
  secret_string = random_password.db.result
}
