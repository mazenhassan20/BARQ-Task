data "aws_availability_zones" "available" {
  state = "available"
}

data "aws_ami" "ubuntu_2404" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }

  filter {
    name   = "root-device-type"
    values = ["ebs"]
  }
}

locals {
  name_prefix = var.project_name
  az_a        = data.aws_availability_zones.available.names[0]
  az_b        = data.aws_availability_zones.available.names[1]
}

resource "aws_vpc" "main" {
  cidr_block           = "10.20.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = "${local.name_prefix}-vpc" }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${local.name_prefix}-igw" }
}

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.20.1.0/24"
  availability_zone       = local.az_a
  map_public_ip_on_launch = true
  tags                    = { Name = "${local.name_prefix}-public-${local.az_a}" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }
  tags = { Name = "${local.name_prefix}-public-rt" }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

# RDS subnet group requires private subnets in two distinct Availability Zones.
# No NAT gateway is created, avoiding its ongoing hourly and data-processing charges.
resource "aws_subnet" "db_a" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.20.10.0/24"
  availability_zone       = local.az_a
  map_public_ip_on_launch = false
  tags                    = { Name = "${local.name_prefix}-db-private-${local.az_a}" }
}

resource "aws_subnet" "db_b" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.20.11.0/24"
  availability_zone       = local.az_b
  map_public_ip_on_launch = false
  tags                    = { Name = "${local.name_prefix}-db-private-${local.az_b}" }
}

resource "aws_route_table" "private_db" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${local.name_prefix}-db-private-rt" }
}

resource "aws_route_table_association" "db_a" {
  subnet_id      = aws_subnet.db_a.id
  route_table_id = aws_route_table.private_db.id
}

resource "aws_route_table_association" "db_b" {
  subnet_id      = aws_subnet.db_b.id
  route_table_id = aws_route_table.private_db.id
}

resource "aws_security_group" "nodes" {
  name        = "${local.name_prefix}-nodes-sg"
  description = "SSH restricted to the approved client; Kubernetes node traffic limited to this node group."
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "SSH from approved client IP only"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.ssh_allowed_cidr]
  }

  ingress {
    description = "Kubernetes API server from approved client IP only"
    from_port   = 6443
    to_port     = 6443
    protocol    = "tcp"
    cidr_blocks = [var.ssh_allowed_cidr]
  }

  ingress {
    description = "BARQ NGINX NodePort"
    from_port   = 30080
    to_port     = 30080
    protocol    = "tcp"
    cidr_blocks = var.app_allowed_cidrs
  }

  ingress {
    description = "Inter-node Kubernetes and CNI traffic between members of this security group"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    self        = true
  }

  egress {
    description = "Outbound access for package installation and image pulls"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${local.name_prefix}-nodes-sg" }
}

resource "aws_security_group" "rds" {
  name        = "${local.name_prefix}-rds-sg"
  description = "PostgreSQL access only from the Kubernetes EC2 node security group."
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "PostgreSQL from application/cluster nodes only"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.nodes.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${local.name_prefix}-rds-sg" }
}

# A minimal EC2 role for Systems Manager access; SSH remains available for the assignment.
resource "aws_iam_role" "ec2_ssm" {
  name = "${local.name_prefix}-ec2-ssm-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
  tags = { Name = "${local.name_prefix}-ec2-ssm-role" }
}

resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.ec2_ssm.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "ec2" {
  name = "${local.name_prefix}-ec2-profile"
  role = aws_iam_role.ec2_ssm.name
  tags = { Name = "${local.name_prefix}-ec2-profile" }
}

resource "aws_instance" "control_plane" {
  ami                         = "ami-09d835910a77f135c"
  instance_type               = var.control_plane_instance_type
  subnet_id                   = aws_subnet.public.id
  associate_public_ip_address = true
  vpc_security_group_ids      = [aws_security_group.nodes.id]
  key_name                    = var.key_pair_name
  iam_instance_profile        = aws_iam_instance_profile.ec2.name

  root_block_device {
    volume_size           = var.root_volume_size_gb
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = true
  }

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
  }

  tags = { Name = "${local.name_prefix}-control-plane", Role = "control-plane" }
}

resource "aws_instance" "worker" {
  ami                         = "ami-09d835910a77f135c"
  instance_type               = var.worker_instance_type
  subnet_id                   = aws_subnet.public.id
  associate_public_ip_address = true
  vpc_security_group_ids      = [aws_security_group.nodes.id]
  key_name                    = var.key_pair_name
  iam_instance_profile        = aws_iam_instance_profile.ec2.name

  root_block_device {
    volume_size           = var.root_volume_size_gb
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = true
  }

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
  }

  tags = { Name = "${local.name_prefix}-worker", Role = "worker" }
}

resource "aws_db_subnet_group" "main" {
  name        = "${local.name_prefix}-db-subnets"
  description = "Private subnet group for BARQ PostgreSQL RDS."
  subnet_ids  = [aws_subnet.db_a.id, aws_subnet.db_b.id]
  tags        = { Name = "${local.name_prefix}-db-subnets" }
}

resource "aws_db_instance" "postgres" {
  identifier                 = "barq-postgres-lab"
  engine                     = "postgres"
  instance_class             = var.db_instance_class
  allocated_storage          = var.db_allocated_storage_gb
  storage_type               = "gp3"
  db_name                    = var.db_name
  username                   = var.db_username
  password                   = var.db_password
  port                       = 5432
  db_subnet_group_name       = aws_db_subnet_group.main.name
  vpc_security_group_ids     = [aws_security_group.rds.id]
  publicly_accessible        = false
  multi_az                   = false
  storage_encrypted          = true
  backup_retention_period    = 0
  auto_minor_version_upgrade = true
  deletion_protection        = false
  skip_final_snapshot        = true
  apply_immediately          = true

  tags = { Name = "${local.name_prefix}-postgres", Role = "database" }
}
