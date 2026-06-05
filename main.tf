# ----------------------------------------------------------------------------
# Provider e configurazione di base
# ----------------------------------------------------------------------------
terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = "eu-west-1"
  default_tags {
    tags = {
      lab = "terraform-aws"
    }
  }
}

# ----------------------------------------------------------------------------
# Task 4: S3 bucket per ALB access logs
# ----------------------------------------------------------------------------
data "aws_elb_service_account" "main" {}

resource "random_id" "alb_logs_suffix" {
  byte_length = 4
}

resource "aws_s3_bucket" "alb_logs" {
  bucket        = "terraform-lab-alb-logs-${random_id.alb_logs_suffix.hex}"
  force_destroy = true
  tags = {
    Name = "terraform-lab-alb-logs"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "alb_logs" {
  bucket = aws_s3_bucket.alb_logs.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "alb_logs" {
  bucket                  = aws_s3_bucket.alb_logs.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "alb_logs" {
  bucket = aws_s3_bucket.alb_logs.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_policy" "alb_logs" {
  bucket = aws_s3_bucket.alb_logs.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { AWS = data.aws_elb_service_account.main.arn }
      Action    = "s3:PutObject"
      Resource  = "${aws_s3_bucket.alb_logs.arn}/*"
    }]
  })
}

# ----------------------------------------------------------------------------
# Rete (VPC e Subnet) con ignore per tfsec
# ----------------------------------------------------------------------------
resource "aws_vpc" "main" {
  cidr_block           = "10.20.0.0/16"
  enable_dns_hostnames = true
}

# tfsec:ignore:aws-ec2-no-public-ip-subnet subnet pubblica voluta per evitare NAT GW nel lab
resource "aws_subnet" "public_a" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.20.1.0/24"
  availability_zone = "eu-west-1a"
}

# tfsec:ignore:aws-ec2-no-public-ip-subnet subnet pubblica voluta per evitare NAT GW nel lab
resource "aws_subnet" "public_b" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.20.2.0/24"
  availability_zone = "eu-west-1b"
}

# ----------------------------------------------------------------------------
# Load Balancer con fix e ignore integrati
# ----------------------------------------------------------------------------
# tfsec:ignore:aws-elb-alb-not-public lab espone deliberatamente un ALB pubblico
resource "aws_lb" "lab" {
  name               = "terraform-lab-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = ["sg-12345678"] # placeholder di sicurezza
  subnets            = [aws_subnet.public_a.id, aws_subnet.public_b.id]
  
  drop_invalid_header_fields = true

  access_logs {
    bucket  = aws_s3_bucket.alb_logs.id
    enabled = true
    prefix  = "alb"
  }
}

# tfsec:ignore:aws-elb-http-not-used lab senza dominio/cert ACM, HTTPS fuori scope
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.lab.arn
  port              = "80"
  protocol          = "HTTP"

  default_action {
    type = "fixed-response"
    fixed_response {
      content_type = "text/plain"
      message_body = "OK"
      status_code  = "200"
    }
  }
}

# ----------------------------------------------------------------------------
# Database RDS con Crittografia abilitata (Fix 1)
# ----------------------------------------------------------------------------
resource "aws_db_instance" "lab" {
  identifier             = "terraform-lab-db"
  engine                 = "mysql"
  engine_version         = "8.0"
  instance_class         = "db.t3.micro"
  allocated_storage      = 20
  storage_encrypted      = true
  db_name                = "labdb"
  username               = "labadmin"
  password               = "SuperSecretPassword123!"
  skip_final_snapshot    = true
}
