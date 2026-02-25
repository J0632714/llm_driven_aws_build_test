variable "git_repo_url" {
  description = "Git repository URL"
  type        = string
  default     = "https://github.com/J0632714/llm_driven_aws_build_test.git"
}

variable "repo_name" {
  description = "Repository name after clone"
  type        = string
  default     = "llm_driven_aws_build_test"
}

provider "aws" {
  region = "ap-northeast-1"
}

resource "aws_key_pair" "deployer" {
  key_name   = "ec2_app_deploy_key"
  public_key = file("~/.ssh/id_rsa.pub")
}

resource "aws_security_group" "app_sg" {
  name        = "app_ec2_sg"
  description = "Allow port 8000"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description      = "Allow HTTP for FastAPI"
    from_port        = 8000
    to_port          = 8000
    protocol         = "tcp"
    cidr_blocks      = ["0.0.0.0/0"]
  }

  egress {
    from_port        = 0
    to_port          = 0
    protocol         = "-1"
    cidr_blocks      = ["0.0.0.0/0"]
  }
}

data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-22.04-amd64-server-*"]
  }
}

data "aws_vpc" "default" {
  default = true
}

data "aws_subnet_ids" "default" {
  vpc_id = data.aws_vpc.default.id
}

resource "aws_instance" "app" {
  ami                         = data.aws_ami.ubuntu.id
  instance_type               = "t3.micro"
  subnet_id                   = data.aws_subnet_ids.default.ids[0]
  vpc_security_group_ids      = [aws_security_group.app_sg.id]
  key_name                    = aws_key_pair.deployer.key_name

  tags = {
    Name = "fastapi-app-server"
  }

  user_data = <<-EOF
    #!/bin/bash
    set -e

    adduser --disabled-password --gecos "" appuser
    apt-get update
    apt-get install -y python3 python3-venv git

    cd /home/appuser
    git clone ${var.git_repo_url}
    chown -R appuser:appuser /home/appuser/${var.repo_name}

    cd /home/appuser/${var.repo_name}/app

    sudo -u appuser python3 -m venv venv
    sudo -u appuser /home/appuser/${var.repo_name}/app/venv/bin/pip install --upgrade pip
    sudo -u appuser /home/appuser/${var.repo_name}/app/venv/bin/pip install -r requirements.txt

    if [ -f /home/appuser/${var.repo_name}/app/.env ]; then
      cp /home/appuser/${var.repo_name}/app/.env /home/appuser/${var.repo_name}/app/.env
    fi

    cat << EOT > /etc/systemd/system/fastapi-app.service
    [Unit]
    Description=FastAPI Uvicorn App
    After=network.target

    [Service]
    User=appuser
    Group=appuser
    WorkingDirectory=/home/appuser/${var.repo_name}/app
    EnvironmentFile=/home/appuser/${var.repo_name}/app/.env
    ExecStart=/home/appuser/${var.repo_name}/app/venv/bin/uvicorn backend.main:app --host 0.0.0.0 --port 8000
    Restart=always

    [Install]
    WantedBy=multi-user.target
    EOT

    chown appuser:appuser /etc/systemd/system/fastapi-app.service
    systemctl daemon-reload
    systemctl enable fastapi-app
    systemctl start fastapi-app
  EOF
}