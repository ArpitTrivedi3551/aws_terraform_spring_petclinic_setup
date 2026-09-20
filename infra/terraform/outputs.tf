output "app_url" {
  description = "Public URL of the application (via the load balancer)."
  value       = "http://${aws_lb.this.dns_name}"
}

output "alb_dns_name" {
  description = "DNS name of the Application Load Balancer."
  value       = aws_lb.this.dns_name
}

output "app_instance_id" {
  description = "EC2 instance ID. The CD pipeline targets this via SSM."
  value       = aws_instance.app.id
}

output "rds_endpoint" {
  description = "PostgreSQL endpoint (host)."
  value       = aws_db_instance.this.address
}

output "db_secret_arn" {
  description = "ARN of the Secrets Manager secret holding the DB password."
  value       = aws_secretsmanager_secret.db.arn
}

output "vpc_id" {
  value = aws_vpc.this.id
}

output "public_subnet_ids" {
  value = aws_subnet.public[*].id
}

output "private_subnet_ids" {
  value = aws_subnet.private[*].id
}
