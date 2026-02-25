terraform {
  required_version = ">= 1.3.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
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

variable "ssh_public_key_path" {
  type        = string
  description = "実行時に -var=ssh_public_key_path=/絶対パス/id_rsa.pub を渡すこと。例: terraform plan -var=\"ssh_public_key_path=$(readlink -f ~/.ssh/id_rsa.pub)\""
}

variable "instance_type" {
  type    = string
  default = "t3.micro"
}

variable "vpc_id" {
  type    = string
  default = null
}

variable "subnet_id" {
  type    = string
  default = null
}

data "aws_vpcs" "default" {
  filter {
    name   = "is-default"
    values = ["true"]
  }
}

data "aws_vpcs" "all" {
  filter {
    name   = "state"
    values = ["available"]
  }
}

locals {
  vpc_id = var.vpc_id != null ? var.vpc_id : (
    length(tolist(data.aws_vpcs.default.ids)) > 0 ?
    tolist(data.aws_vpcs.default.ids)[0] :
    tolist(data.aws_vpcs.all.ids)[0]
  )
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [local.vpc_id]
  }
}

locals {
  first_subnet_id      = var.subnet_id != null ? var.subnet_id : tolist(data.aws_subnets.default.ids)[0]
  associate_public_ip  = var.subnet_id == null
}

data "aws_ami" "amazon_linux" {
  most_recent = true

  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }

  owners = ["137112412989"]
}

resource "aws_key_pair" "app_key" {
  key_name   = "fastapi-app-key"
  public_key = file(var.ssh_public_key_path)
}

resource "aws_security_group" "app_sg" {
  name        = "fastapi-app-sg"
  description = "Security group for FastAPI app on port 8000"
  vpc_id      = local.vpc_id

  ingress {
    description = "Allow HTTP for FastAPI on port 8000"
    from_port   = 8000
    to_port     = 8000
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }

  tags = {
    Name = "fastapi-app-sg"
  }
}

resource "aws_instance" "app" {
  ami                         = data.aws_ami.amazon_linux.id
  instance_type               = var.instance_type
  subnet_id                   = local.first_subnet_id
  vpc_security_group_ids      = [aws_security_group.app_sg.id]
  key_name                    = aws_key_pair.app_key.key_name
  associate_public_ip_address = local.associate_public_ip

  user_data = <<-EOF
    #!/bin/bash
    set -eux

    adduser --disabled-password --gecos "" appuser || true

    dnf update -y
    dnf install -y git python3 python3-pip python3-venv

    su - appuser -c "git clone ${var.git_repo_url}"

    APP_HOME=/home/appuser/${var.repo_name}/app

    su - appuser -c "cd ${var.repo_name}/app && python3 -m venv venv"
    su - appuser -c "cd ${var.repo_name}/app && ./venv/bin/pip install --upgrade pip"
    su - appuser -c "cd ${var.repo_name}/app && ./venv/bin/pip install -r requirements.txt"

    if [ ! -f /home/appuser/${var.repo_name}/app/.env ]; then
      cp /home/appuser/${var.repo_name}/app/.env.example /home/appuser/${var.repo_name}/app/.env 2>/dev/null || true
    fi

    chown -R appuser:appuser /home/appuser/${var.repo_name}

    cat >/etc/systemd/system/fastapi-app.service << 'SERVICEEOF'
    [Unit]
    Description=FastAPI application service
    After=network.target

    [Service]
    User=appuser
    Group=appuser
    WorkingDirectory=/home/appuser/${var.repo_name}/app
    EnvironmentFile=-/home/appuser/${var.repo_name}/app/.env
    ExecStart=/home/appuser/${var.repo_name}/app/venv/bin/uvicorn backend.main:app --host 0.0.0.0 --port 8000
    Restart=always
    RestartSec=5

    [Install]
    WantedBy=multi-user.target
    SERVICEEOF

    systemctl daemon-reload
    systemctl enable fastapi-app.service
    systemctl start fastapi-app.service
  EOF

  tags = {
    Name = "fastapi-ec2-app"
  }
}