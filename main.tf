terraform {
  required_version = ">= 1.3.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }
}

provider "aws" {
  region = "ap-northeast-1"
}

variable "git_repo_url" {
  type    = string
  default = "https://github.com/J0632714/llm_driven_aws_build_test.git"
}

variable "repo_name" {
  type    = string
  default = "llm_driven_aws_build_test"
}

variable "vpc_id" {
  type    = string
  default = ""
}

variable "ssh_public_key_path" {
  type        = string
  default     = "~/.ssh/id_rsa.pub"
  description = "Path to your SSH public key file (absolute path is recommended; Terraform file() does not expand ~)."
}

data "aws_vpc" "default" {
  count   = var.vpc_id == "" ? 1 : 0
  default = true
}

data "aws_vpc" "selected" {
  count = var.vpc_id != "" ? 1 : 0
  id    = var.vpc_id
}

locals {
  vpc_id = var.vpc_id != "" ? var.vpc_id : data.aws_vpc.default[0].id
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [local.vpc_id]
  }
}

locals {
  first_subnet_id = tolist(data.aws_subnets.default.ids)[0]
}

resource "aws_key_pair" "app_key" {
  key_name   = "app-key"
  public_key = file(var.ssh_public_key_path)
}

resource "aws_security_group" "app_sg" {
  name        = "fastapi-app-sg"
  description = "Security group for FastAPI app"
  vpc_id      = local.vpc_id

  ingress {
    description = "Allow HTTP on app port"
    from_port   = 8000
    to_port     = 8000
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "Allow SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "Allow all outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "fastapi-app-sg"
  }
}

data "aws_ami" "amazon_linux" {
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
  ami                    = data.aws_ami.amazon_linux.id
  instance_type          = "t3.micro"
  subnet_id              = local.first_subnet_id
  vpc_security_group_ids = [aws_security_group.app_sg.id]
  key_name               = aws_key_pair.app_key.key_name
  associate_public_ip_address = true

  user_data = <<-EOF
    #!/bin/bash
    set -euxo pipefail

    # Create app user
    id appuser >/dev/null 2>&1 || useradd -m -s /bin/bash appuser

    # Install system updates and packages
    dnf update -y
    dnf install -y git python3 python3-pip python3-venv

    # Switch to appuser home
    cd /home/appuser

    # Clone repository
    if [ ! -d "/home/appuser/${var.repo_name}" ]; then
      git clone ${var.git_repo_url}
    fi

    cd /home/appuser/${var.repo_name}/app

    # Create virtual environment
    python3 -m venv venv
    source venv/bin/activate
    pip install --upgrade pip
    if [ -f requirements.txt ]; then
      pip install -r requirements.txt
    fi

    # .env handling - copy .env.example only if .env does not exist
    if [ ! -f /home/appuser/${var.repo_name}/app/.env ]; then
      cp /home/appuser/${var.repo_name}/app/.env.example /home/appuser/${var.repo_name}/app/.env 2>/dev/null || true
    fi

    # Create systemd service for the FastAPI app
    cat >/etc/systemd/system/fastapi-app.service <<SERVICE
    [Unit]
    Description=FastAPI app with Uvicorn
    After=network.target

    [Service]
    Type=simple
    User=appuser
    WorkingDirectory=/home/appuser/${var.repo_name}/app
    EnvironmentFile=-/home/appuser/${var.repo_name}/app/.env
    ExecStart=/home/appuser/${var.repo_name}/app/venv/bin/uvicorn backend.main:app --host 0.0.0.0 --port 8000
    Restart=always
    RestartSec=5

    [Install]
    WantedBy=multi-user.target
    SERVICE

    # Permissions
    chown -R appuser:appuser /home/appuser/${var.repo_name}

    # Reload systemd and start service
    systemctl daemon-reload
    systemctl enable fastapi-app.service
    systemctl start fastapi-app.service
  EOF

  tags = {
    Name = "fastapi-app-ec2"
  }
}