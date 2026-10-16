variable "aws_region" {
  description = "AWS region for this assignment."
  type        = string
  default     = "eu-north-1"
}

variable "project_name" {
  description = "Short project identifier used in resource names and tags."
  type        = string
  default     = "barq-aws-assignment"
}

variable "environment" {
  description = "Environment tag."
  type        = string
  default     = "lab"
}

variable "ssh_allowed_cidr" {
  description = "Your current public IPv4 address in CIDR notation, e.g. 203.0.113.10/32. Never use 0.0.0.0/0 for SSH."
  type        = string
  nullable    = false

  validation {
    condition     = can(cidrnetmask(var.ssh_allowed_cidr)) && !contains(["0.0.0.0/0", "::/0"], var.ssh_allowed_cidr)
    error_message = "Set ssh_allowed_cidr to a valid, restricted CIDR (normally your public IPv4 address with /32)."
  }
}

variable "key_pair_name" {
  description = "Name of an existing EC2 key pair in the selected region. Create/import it in eu-north-1 before applying."
  type        = string
  nullable    = false
}

variable "control_plane_instance_type" {
  description = "x86_64 EC2 type for the Kubernetes control-plane node. Check your account quota before apply."
  type        = string
  default     = "c7i-flex.large"
}

variable "worker_instance_type" {
  description = "x86_64 EC2 type for the Kubernetes worker node."
  type        = string
  default     = "t3.small"
}

variable "root_volume_size_gb" {
  description = "Root EBS volume size for each EC2 instance. EBS storage is billed separately from compute."
  type        = number
  default     = 20

  validation {
    condition     = var.root_volume_size_gb >= 8 && var.root_volume_size_gb <= 100
    error_message = "root_volume_size_gb must be between 8 and 100 GiB."
  }
}

variable "db_name" {
  description = "Initial PostgreSQL database name."
  type        = string
  default     = "barqdb"
}

variable "db_username" {
  description = "RDS master username. Supply a non-default username."
  type        = string
  default     = "barqadmin"
}

variable "db_password" {
  description = "RDS master password. Supply through an untracked terraform.tfvars file or TF_VAR_db_password. Terraform state will contain sensitive values."
  type        = string
  sensitive   = true
  nullable    = false

  validation {
    condition     = length(var.db_password) >= 12 && can(regex("[A-Za-z]", var.db_password)) && can(regex("[0-9]", var.db_password))
    error_message = "db_password must be at least 12 characters and contain letters and numbers."
  }
}

variable "db_instance_class" {
  description = "RDS instance class. Verify it is orderable in the selected region/account before apply."
  type        = string
  default     = "db.t3.micro"
}

variable "db_allocated_storage_gb" {
  description = "RDS allocated storage in GiB."
  type        = number
  default     = 20
}

variable "app_allowed_cidrs" {
  type        = list(string)
  default     = ["0.0.0.0/0"]
  description = "Who can reach the NGINX NodePort"
}
