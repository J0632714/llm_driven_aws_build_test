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

resource "aws_key_pair" "app_key" {
  key_name   = "fastapi-app-key"
  public_key = file(var.ssh_public_key_path)
}

resource "aws_security_group" "app_sg" {
  name        = "fastapi-app-sg"
  description = "Security group for FastAPI app on EC2"
  vpc_id      = local.vpc_id

  ingress {
    description = "Allow HTTP access to FastAPI app on port 8000"
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
    set -xe

    # Variables
    APP_USER="appuser"
    APP_HOME="/home/$${APP_USER}"
    REPO_NAME="${var.repo_name}"
    REPO_URL="${var.git_repo_url}"
    APP_DIR="$${APP_HOME}/$${REPO_NAME}/app"
    PYTHON_BIN="/usr/bin/python3"
    VENV_DIR="$${APP_DIR}/venv"
    SERVICE_NAME="fastapi-app.service"
    ENV_FILE="$${APP_DIR}/.env"
    ENV_EXAMPLE_FILE="$${APP_DIR}/.env.example"

    # Update and install packages
    dnf update -y
    dnf install -y git python3-pip python3-venv

    # Create application user
    id -u $${APP_USER} >/dev/null 2>&1 || useradd -m -s /bin/bash $${APP_USER}

    # Clone repository
    sudo -u $${APP_USER} bash -c "cd $${APP_HOME} && git clone ${var.git_repo_url} || true"

    # Create virtual environment and install dependencies
    sudo -u $${APP_USER} bash -c "
      cd $${APP_HOME}/$${REPO_NAME}/app && \
      $${PYTHON_BIN} -m venv venv && \
      source venv/bin/activate && \
      pip install --upgrade pip && \
      if [ -f requirements.txt ]; then pip install -r requirements.txt; fi
    "

    # Prepare .env if missing
    if [ ! -f "$${ENV_FILE}" ]; then
      if [ -f "$${ENV_EXAMPLE_FILE}" ]; then
        cp "$${ENV_EXAMPLE_FILE}" "$${ENV_FILE}" 2>/dev/null || true
      fi
    fi

    # Fix ownership
    chown -R $${APP_USER}:$${APP_USER} "$${APP_HOME}/$${REPO_NAME}"

    # Create systemd service
    cat >/etc/systemd/system/$${SERVICE_NAME} <<SERVICE_EOF
    [Unit]
    Description=FastAPI app with Uvicorn
    After=network.target

    [Service]
    Type=simple
    User=$${APP_USER}
    WorkingDirectory=$${APP_HOME}/$${REPO_NAME}/app
    EnvironmentFile=$${APP_HOME}/$${REPO_NAME}/app/.env
    ExecStart=$${APP_HOME}/$${REPO_NAME}/app/venv/bin/uvicorn backend.main:app --host 0.0.0.0 --port 8000
    Restart=always
    RestartSec=5

    [Install]
    WantedBy=multi-user.target
    SERVICE_EOF

    # Reload systemd and start service
    systemctl daemon-reload
    systemctl enable $${SERVICE_NAME}
    systemctl start $${SERVICE_NAME}
  EOF

  tags = {
    Name = "fastapi-app-ec2"
  }
}

output "ec2_public_ip" {
  value = aws_instance.app.public_ip
}

output "fastapi_app_url" {
  value = "http://${aws_instance.app.public_ip}:8000"
}