terraform {
  required_version = ">= 1.5.0"

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
  description = "Git repository URL for the whole project (app exists under app/)."
}

variable "repo_name" {
  type        = string
  default     = "llm_driven_aws_build_test"
  description = "Repository name (directory name after cloning)."
}

variable "ssh_public_key_path" {
  type        = string
  description = "実行時に -var=ssh_public_key_path=/絶対パス/id_rsa.pub を渡すこと。例: terraform plan -var=\"ssh_public_key_path=$(readlink -f ~/.ssh/id_rsa.pub)\""
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
  vpc_id = length(tolist(data.aws_vpcs.default.ids)) > 0 ? tolist(data.aws_vpcs.default.ids)[0] : tolist(data.aws_vpcs.all.ids)[0]
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

data "aws_ami" "amazon_linux_2" {
  most_recent = true

  owners = ["amazon"]

  filter {
    name   = "name"
    values = ["amzn2-ami-hvm-*-x86_64-gp2"]
  }

  filter {
    name   = "state"
    values = ["available"]
  }
}

resource "aws_key_pair" "app_key" {
  key_name   = "fastapi-app-key"
  public_key = file(var.ssh_public_key_path)
}

resource "aws_security_group" "app_sg" {
  name        = "fastapi-app-sg"
  description = "Security group for FastAPI app on EC2"
  vpc_id      = local.vpc_id

  ingress {
    description = "Allow HTTP access to FastAPI app (port 8000)"
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
    description = "Allow all outbound traffic"
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
  ami                    = data.aws_ami.amazon_linux_2.id
  instance_type          = "t3.micro"
  subnet_id              = local.first_subnet_id
  vpc_security_group_ids = [aws_security_group.app_sg.id]
  key_name               = aws_key_pair.app_key.key_name

  associate_public_ip_address = true

  user_data = <<-EOF
              #!/bin/bash
              set -xe

              # Create app user
              id appuser >/dev/null 2>&1 || useradd -m -s /bin/bash appuser

              # Update system and install dependencies
              yum update -y
              yum install -y git python3 python3-pip python3-venv # on Amazon Linux 2, python3-venv may not exist but ignore errors
              yum install -y systemd

              # Ensure systemd is PID 1 (on EC2 this is normally true)

              # Switch to appuser home
              cd /home/appuser

              # Clone the whole repository
              if [ ! -d "/home/appuser/${var.repo_name}" ]; then
                git clone ${var.git_repo_url}
              fi

              cd /home/appuser/${var.repo_name}/app

              # Create virtual environment
              python3 -m venv venv || /usr/bin/python3 -m venv venv
              source venv/bin/activate

              # Upgrade pip and install requirements
              pip install --upgrade pip
              if [ -f requirements.txt ]; then
                pip install -r requirements.txt
              fi

              # Prepare .env only if it does not exist
              if [ ! -f /home/appuser/${var.repo_name}/app/.env ]; then
                if [ -f /home/appuser/${var.repo_name}/app/.env.example ]; then
                  cp /home/appuser/${var.repo_name}/app/.env.example /home/appuser/${var.repo_name}/app/.env 2>/dev/null || true
                fi
              fi

              # Create systemd service for FastAPI app
              cat >/etc/systemd/system/fastapi-app.service <<'SERVICE'
              [Unit]
              Description=FastAPI application with Uvicorn
              After=network.target

              [Service]
              Type=simple
              User=appuser
              Group=appuser
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

output "instance_public_ip" {
  description = "Public IP of the FastAPI EC2 instance"
  value       = aws_instance.fastapi_app.public_ip
}

output "app_url" {
  description = "URL to access the FastAPI app"
  value       = "http://${aws_instance.fastapi_app.public_ip}:8000"
}