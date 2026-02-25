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
  description = "Git repository URL that contains the app/ directory."
}

variable "repo_name" {
  type        = string
  default     = "llm_driven_aws_build_test"
  description = "Repository name (directory name after git clone)."
}

variable "ssh_public_key_path" {
  type        = string
  default     = "~/.ssh/id_rsa.pub"
  description = "Path to your SSH public key file (absolute path is recommended)."
}

data "aws_ami" "amazon_linux_2" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["amzn2-ami-hvm-*-x86_64-gp2"]
  }
}

data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

locals {
  first_subnet_id = tolist(data.aws_subnets.default.ids)[0]
}

resource "aws_key_pair" "default" {
  key_name   = "fastapi-app-key"
  public_key = file(var.ssh_public_key_path)
}

resource "aws_security_group" "fastapi_sg" {
  name        = "fastapi-app-sg"
  description = "Security group for FastAPI app"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description = "Allow HTTP for FastAPI app on port 8000"
    from_port   = 8000
    to_port     = 8000
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }

  ingress {
    description = "Allow SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }

  egress {
    description = "Allow all outbound traffic"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }
}

resource "aws_instance" "fastapi_app" {
  ami                    = data.aws_ami.amazon_linux_2.id
  instance_type          = "t3.micro"
  subnet_id              = local.first_subnet_id
  vpc_security_group_ids = [aws_security_group.fastapi_sg.id]
  key_name               = aws_key_pair.default.key_name

  user_data = <<-EOF
              #!/bin/bash
              set -euxo pipefail

              # Create app user
              id appuser &>/dev/null || useradd -m -s /bin/bash appuser

              # Update system
              yum update -y

              # Install dependencies
              yum install -y git python3 python3-pip
              python3 -m pip install --upgrade pip

              # Clone repository as appuser
              su - appuser -c "git clone ${var.git_repo_url}"

              # Create virtual environment
              su - appuser -c "python3 -m venv /home/appuser/${var.repo_name}/app/venv"

              # Install Python dependencies
              su - appuser -c \"/home/appuser/${var.repo_name}/app/venv/bin/pip install --upgrade pip\"
              su - appuser -c \"/home/appuser/${var.repo_name}/app/venv/bin/pip install -r /home/appuser/${var.repo_name}/app/requirements.txt\"

              # Prepare .env if not exists
              if [ ! -f /home/appuser/${var.repo_name}/app/.env ]; then
                cp /home/appuser/${var.repo_name}/app/.env.example /home/appuser/${var.repo_name}/app/.env 2>/dev/null || true
              fi

              chown -R appuser:appuser /home/appuser/${var.repo_name}

              # Create systemd service
              cat << 'SERVICE' > /etc/systemd/system/fastapi-app.service
              [Unit]
              Description=FastAPI Application Service
              After=network.target

              [Service]
              Type=simple
              User=appuser
              Group=appuser
              WorkingDirectory=/home/appuser/${var.repo_name}/app
              EnvironmentFile=/home/appuser/${var.repo_name}/app/.env
              ExecStart=/home/appuser/${var.repo_name}/app/venv/bin/uvicorn backend.main:app --host 0.0.0.0 --port 8000
              Restart=always
              RestartSec=5

              [Install]
              WantedBy=multi-user.target
              SERVICE

              # Reload systemd and start service
              systemctl daemon-reload
              systemctl enable fastapi-app
              systemctl start fastapi-app
              EOF

  tags = {
    Name = "fastapi-app-ec2"
  }
}