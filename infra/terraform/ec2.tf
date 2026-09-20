data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }
  filter {
    name   = "architecture"
    values = ["x86_64"]
  }
}

resource "aws_instance" "app" {
  ami                         = data.aws_ami.al2023.id
  instance_type               = var.app_instance_type
  subnet_id                   = aws_subnet.public[0].id
  vpc_security_group_ids      = [aws_security_group.app.id]
  associate_public_ip_address = true
  iam_instance_profile        = aws_iam_instance_profile.app.name

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required" # enforce IMDSv2
  }

  root_block_device {
    volume_type = "gp3"
    volume_size = 20
  }

  user_data = templatefile("${path.module}/files/app_user_data.sh.tftpl", {
    region     = var.aws_region
    secret_arn = aws_secretsmanager_secret.db.arn
    app_image  = var.app_image
    db_host    = aws_db_instance.this.address
    db_name    = var.db_name
    db_user    = var.db_username
    app_port   = var.app_port
  })

  # Deploys happen through SSM (Part 2), not by rebuilding the box, so don't
  # let user_data / AMI drift trigger a replacement.
  lifecycle {
    ignore_changes = [user_data, ami]
  }

  depends_on = [aws_db_instance.this]

  tags = { Name = "${local.name_prefix}-app" }
}
