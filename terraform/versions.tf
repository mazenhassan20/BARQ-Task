terraform {
  required_version = ">= 1.6.0"

  # tf state lock s3 bucket
  backend "s3" {
    bucket       = "barq-terraform-state-mazen"
    key          = "barq-aws-assignment/terraform.tfstate"
    region       = "eu-north-1"
    encrypt      = true
    use_lockfile = true
  }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.80"
    }
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = var.project_name
      Environment = var.environment
      ManagedBy   = "Terraform"
    }
  }
}
