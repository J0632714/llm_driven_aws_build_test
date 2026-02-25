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
  type        = string
  default     = "https://github.com/J0632714/llm_driven_aws_build_test.git"
  description = "Git repository URL that contains the app/ directory"
}

variable "repo_name" {
  type        = string
  default     = "llm_driven_aws_build_test"
  description = "Repository name (directory created after git clone)"
}

variable "ssh_public_key_path" {
  type        = string
  default     = "~/.ssh/id_rsa.pub"
  description = "Path to your SSH public key file (absolute path is recommended)"
}

variable "instance_type" {
  type        = string
  default     = "t3.micro"
  description = "EC2 instance type for FastAPI app"
}

variable "key_pair_name" {
  type        = string
  default     = "fastapi-app-key"
  description = "Name of the EC2 key pair"
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
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["amzn2-ami-hvm-*-x86_64-gp2"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

resource "aws_key_pair" "this" {
  key_name   = var.key_pair_name
  public_key = file(var.ssh_public_key_path)
}

resource "aws_security_group" "fastapi_sg" {
  name        = "fastapi-app-sg"
  description = "Security group for FastAPI app on port 8000"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description = "Allow HTTP traffic to FastAPI app"
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
  instance_type          = var.instance_type
  subnet_id              = local.first_subnet_id
  vpc_security_group_ids = [aws_security_group.fastapi_sg.id]
  key_name               = aws_key_pair.this.key_name
  associate_public_ip_address = true

  user_data = <<-EOF
              #!/bin/bash
              set -xe

              # Create application user
              id appuser &>/dev/null || useradd -m -s /bin/bash appuser

              # Install system packages
              yum update -y
              yum install -y git python3 python3-pip

              # Ensure pip / venv
              python3 -m pip install --upgrade pip
              python3 -m pip install virtualenv

              # Switch to appuser home
              cd /home/appuser

              # Clone repository
              if [ ! -d "/home/appuser/${var.repo_name}" ]; then
                git clone ${var.git_repo_url}
              fi

              cd /home/appuser/${var.repo_name}/app

              # Create virtual environment
              python3 -m venv venv
              chown -R appuser:appuser /home/appuser/${var.repo_name}

              # Activate venv and install dependencies
              su - appuser -c "cd /home/appuser/${var.repo_name}/app && source venv/bin/activate && pip install --upgrade pip && pip install -r requirements.txt"

              # Ensure .env exists (copy from .env.example only if .env does not exist)
              if [ ! -f /home/appuser/${var.repo_name}/app/.env ]; then
                cp /home/appuser/${var.repo_name}/app/.env.example /home/appuser/${var.repo_name}/app/.env 2>/dev/null || true
              fi

              # Create systemd service
              cat >/etc/systemd/system/fastapi-app.service << 'EOL'
              [Unit]
              Description=FastAPI app service
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
              EOL

              # Permissions and service enable
              chown -R appuser:appuser /home/appuser/${var.repo_name}
              systemctl daemon-reload
              systemctl enable fastapi-app.service
              systemctl start fastapi-app.service
              EOF

  tags = {
    Name = "fastapi-app-ec2"
  }
}