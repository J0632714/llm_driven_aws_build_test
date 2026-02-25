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
  type        = string
  default     = "https://github.com/J0632714/llm_driven_aws_build_test.git"
  description = "Git リポジトリの URL（このプロジェクト全体を clone する）"
}

variable "repo_name" {
  type        = string
  default     = "llm_driven_aws_build_test"
  description = "Git リポジトリ名（clone 後のディレクトリ名）"
}

variable "ssh_public_key_path" {
  type        = string
  default     = "~/.ssh/id_rsa.pub"
  description = "SSH 公開鍵ファイルのパス（絶対パスを推奨）"
}

variable "instance_type" {
  type        = string
  default     = "t3.micro"
  description = "EC2 インスタンスタイプ"
}

data "aws_vpc" "default" {
  default = true
}

data "aws_subnet_ids" "default" {
  vpc_id = data.aws_vpc.default.id
}

locals {
  first_subnet_id = tolist(data.aws_subnet_ids.default.ids)[0]
}

data "aws_ami" "amazon_linux_2" {
  owners      = ["amazon"]
  most_recent = true
  filter {
    name   = "name"
    values = ["amzn2-ami-hvm-*-x86_64-gp2"]
  }
  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

resource "aws_key_pair" "app_key" {
  key_name   = "fastapi-app-key"
  public_key = file(var.ssh_public_key_path)
}

resource "aws_security_group" "fastapi_sg" {
  name        = "fastapi-app-sg"
  description = "Security group for FastAPI app on port 8000"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description = "Allow FastAPI app port 8000"
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
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "fastapi-app-sg"
  }
}

resource "aws_instance" "fastapi_app" {
  ami                         = data.aws_ami.amazon_linux_2.id
  instance_type               = var.instance_type
  subnet_id                   = local.first_subnet_id
  vpc_security_group_ids      = [aws_security_group.fastapi_sg.id]
  associate_public_ip_address = true
  key_name                    = aws_key_pair.app_key.key_name

  user_data = <<-EOF
    #!/bin/bash
    set -euxo pipefail

    # Create application user
    id appuser || useradd -m -s /bin/bash appuser

    # Install dependencies
    yum update -y
    yum install -y git python3 python3-pip

    # Clone the entire repository into appuser's home
    su - appuser -c "git clone ${var.git_repo_url}"

    # Move to app directory and set up virtualenv
    su - appuser -c "cd ${var.repo_name}/app && python3 -m venv /home/appuser/${var.repo_name}/app/.venv"

    # Install Python dependencies
    su - appuser -c "/home/appuser/${var.repo_name}/app/.venv/bin/pip install --upgrade pip"
    su - appuser -c "/home/appuser/${var.repo_name}/app/.venv/bin/pip install -r /home/appuser/${var.repo_name}/app/requirements.txt"

    # Prepare .env if missing
    if [ ! -f /home/appuser/${var.repo_name}/app/.env ]; then cp /home/appuser/${var.repo_name}/app/.env.example /home/appuser/${var.repo_name}/app/.env 2>/dev/null || true; fi

    # Ensure ownership of app directory
    chown -R appuser:appuser /home/appuser/${var.repo_name}/app

    # Create systemd service
    cat > /etc/systemd/system/fastapi-app.service <<SERVICE
    [Unit]
    Description=FastAPI App (Uvicorn)
    After=network.target

    [Service]
    Type=simple
    User=appuser
    WorkingDirectory=/home/appuser/${var.repo_name}/app
    EnvironmentFile=/home/appuser/${var.repo_name}/app/.env
    ExecStart=/home/appuser/${var.repo_name}/app/.venv/bin/python -m uvicorn backend.main:app --host 0.0.0.0 --port 8000
    Restart=always
    RestartSec=5
    Environment=PATH=/home/appuser/${var.repo_name}/app/.venv/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin

    [Install]
    WantedBy=multi-user.target
    SERVICE

    systemctl daemon-reload
    systemctl enable fastapi-app
    systemctl start fastapi-app
  EOF

  tags = {
    Name = "fastapi-app-ec2"
  }
}

output "instance_public_ip" {
  value = aws_instance.fastapi_app.public_ip
}

output "instance_public_dns" {
  value = aws_instance.fastapi_app.public_dns
}