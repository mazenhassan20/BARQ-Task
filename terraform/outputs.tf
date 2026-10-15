output "region" {
  description = "AWS region used by this deployment."
  value       = var.aws_region
}

output "control_plane_public_ip" {
  description = "Public IPv4 address for SSH access to the control-plane node."
  value       = aws_instance.control_plane.public_ip
}

output "control_plane_private_ip" {
  description = "Private IPv4 address to use for kubeadm init and the Kubernetes API endpoint."
  value       = aws_instance.control_plane.private_ip
}

output "worker_public_ip" {
  description = "Public IPv4 address for SSH access to the worker node."
  value       = aws_instance.worker.public_ip
}

output "worker_private_ip" {
  description = "Private IPv4 address of the worker node."
  value       = aws_instance.worker.private_ip
}

output "rds_endpoint" {
  description = "Private PostgreSQL RDS endpoint hostname (not a public endpoint)."
  value       = aws_db_instance.postgres.address
}

output "rds_port" {
  description = "PostgreSQL port."
  value       = aws_db_instance.postgres.port
}

output "rds_database_name" {
  description = "Initial PostgreSQL database name."
  value       = aws_db_instance.postgres.db_name
}

output "ssh_command_control_plane" {
  description = "Example SSH command; replace the local key path with your private key path."
  value       = "ssh -i <PATH_TO_PRIVATE_KEY> ubuntu@${aws_instance.control_plane.public_ip}"
}

output "ssh_command_worker" {
  description = "Example SSH command; replace the local key path with your private key path."
  value       = "ssh -i <PATH_TO_PRIVATE_KEY> ubuntu@${aws_instance.worker.public_ip}"
}
