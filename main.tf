provider "aws" {
  region = "ap-northeast-1"
}

variable "git_repo_url" {
  description = "Git repository URL"
  type        = string
  default     = "https://github.com/YOUR_USER/llm_driven_aws_build_test.git"
}

variable "repo_name" {
  description = "Repository folder name after clone"
  type        = string
  default     = "llm_driven_aws_build_test"
}

resource "aws_key_pair" "app_key" {
  key_name   = "app-ec2-key"
  public_key = file("~/.ssh/id_rsa.pub")
}

resource "aws_security_group" "app_sg" {
  name        = "app-server-sg"
  description = "Allow SSH and 8000"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Allow SSH"
  }
  ingress {
    from_port   = 8000
    to_port     = 8000
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Allow HTTP for FastAPI"
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"]
  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-20.04-amd64-server-*"]
  }
}

data "aws_vpc" "default" {
  default = true
}

data "aws_subnet_ids" "default" {
  vpc_id = data.aws_vpc.default.id
}

resource "aws_instance" "app" {
  ami             = data.aws_ami.ubuntu.id
  instance_type   = "t3.micro"
  subnet_id       = element(data.aws_subnet_ids.default.ids, 0)
  key_name        = aws_key_pair.app_key.key_name
  security_groups = [aws_security_group.app_sg.id]

  user_data = <<EOF
#!/bin/bash
set -e

# Create appuser
useradd -m -s /bin/bash appuser
echo "appuser ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers

# Install dependencies
apt-get update -y
apt-get install -y git python3 python3-venv python3-pip

# Clone repository
cd /home/appuser
git clone ${var.git_repo_url}
chown -R appuser:appuser /home/appuser/${var.repo_name}

cd /home/appuser/${var.repo_name}/app

# Create venv & install requirements
sudo -u appuser python3 -m venv venv
sudo -u appuser bash -c "source venv/bin/activate && pip install --upgrade pip && pip install -r requirements.txt"

# .env ファイルが必要な場合は適宜/手動でscp等で転送

# Set up systemd service
cat <<EOL > /etc/systemd/system/fastapi_app.service
[Unit]
Description=FastAPI App
After=network.target

[Service]
User=appuser
WorkingDirectory=/home/appuser/${var.repo_name}/app
EnvironmentFile=/home/appuser/${var.repo_name}/app/.env
ExecStart=/home/appuser/${var.repo_name}/app/venv/bin/python -m uvicorn backend.main:app --host 0.0.0.0 --port 8000
Restart=always

[Install]
WantedBy=multi-user.target
EOL

chown appuser:appuser /etc/systemd/system/fastapi_app.service

systemctl daemon-reload
systemctl enable fastapi_app
systemctl start fastapi_app
EOF

  tags = {
    Name = "fastapi-app-server"
  }
}
