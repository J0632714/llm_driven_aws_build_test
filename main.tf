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
  description = "Git repository URL containing the app directory."
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
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["amzn2-ami-hvm-*-x86_64-gp2"]
  }
}

resource "aws_key_pair" "app_key" {
  key_name   = "fastapi-app-key"
  public_key = file(var.ssh_public_key_path)
}

resource "aws_security_group" "fastapi_sg" {
  name        = "fastapi-sg"
  description = "Security group for FastAPI app on EC2"
  vpc_id      = local.vpc_id

  ingress {
    description = "Allow HTTP for FastAPI (port 8000)"
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
    description = "Allow all outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }

  tags = {
    Name = "fastapi-sg"
  }
}

resource "aws_instance" "fastapi_app" {
  ami                         = data.aws_ami.amazon_linux_2.id
  instance_type               = "t3.micro"
  subnet_id                   = local.first_subnet_id
  vpc_security_group_ids      = [aws_security_group.fastapi_sg.id]
  key_name                    = aws_key_pair.app_key.key_name
  associate_public_ip_address = true

  user_data = <<-EOF
              #!/bin/bash
              set -eux

              APP_USER="appuser"
              REPO_URL="${var.git_repo_url}"
              REPO_NAME="${var.repo_name}"
              APP_HOME="/home/${APP_USER}/${REPO_NAME}/app"
              ENV_FILE="${APP_HOME}/.env"
              ENV_EXAMPLE="${APP_HOME}/.env.example"
              VENV_DIR="${APP_HOME}/venv"
              SYSTEMD_SERVICE="/etc/systemd/system/fastapi-app.service"

              # Create app user
              id -u ${APP_USER} >/dev/null 2>&1 || useradd -m -s /bin/bash ${APP_USER}

              # Install system packages
              yum update -y
              yum install -y git python3 python3-pip

              # Adjust PATH for python3
              alternatives --set python /usr/bin/python3 || true

              # Clone repository as appuser
              sudo -u ${APP_USER} -H bash -lc "cd /home/${APP_USER} && git clone ${REPO_URL} || true"

              # Ensure ownership
              chown -R ${APP_USER}:${APP_USER} /home/${APP_USER}

              # Set up virtual environment and install dependencies
              sudo -u ${APP_USER} -H bash -lc "
                cd ${APP_HOME} && \
                python3 -m venv ${VENV_DIR} && \
                source ${VENV_DIR}/bin/activate && \
                pip install --upgrade pip && \
                if [ -f requirements.txt ]; then pip install -r requirements.txt; fi
              "

              # Prepare .env from .env.example only if .env does not exist
              if [ ! -f ${ENV_FILE} ]; then
                if [ -f ${ENV_EXAMPLE} ]; then
                  cp ${ENV_EXAMPLE} ${ENV_FILE} 2>/dev/null || true
                fi
              fi

              chown ${APP_USER}:${APP_USER} ${ENV_FILE} 2>/dev/null || true

              # Create systemd service
              cat > ${SYSTEMD_SERVICE} << EOL
              [Unit]
              Description=FastAPI Application Service
              After=network.target

              [Service]
              Type=simple
              User=${APP_USER}
              Group=${APP_USER}
              WorkingDirectory=${APP_HOME}
              EnvironmentFile=${ENV_FILE}
              ExecStart=${VENV_DIR}/bin/uvicorn backend.main:app --host 0.0.0.0 --port 8000
              Restart=always
              RestartSec=5

              [Install]
              WantedBy=multi-user.target
              EOL

              # Permissions and reload systemd
              chmod 644 ${SYSTEMD_SERVICE}
              systemctl daemon-reload
              systemctl enable fastapi-app.service
              systemctl start fastapi-app.service

              EOF

  tags = {
    Name = "fastapi-ec2-app"
  }
}

output "ec2_public_ip" {
  value = aws_instance.fastapi_app.public_ip
}

output "fastapi_url" {
  value = "http://${aws_instance.fastapi_app.public_dns}:8000"
}