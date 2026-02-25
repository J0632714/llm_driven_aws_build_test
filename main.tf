provider "aws" {
  region = "ap-northeast-1"
}

resource "aws_key_pair" "app_key" {
  key_name   = "app_key"
  public_key = file("~/.ssh/id_rsa.pub")
}

resource "aws_security_group" "app_sg" {
  name        = "app_sg"
  description = "Allow port 8000"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    from_port   = 8000
    to_port     = 8000
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
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
  ami                         = data.aws_ami.ubuntu.id
  instance_type               = "t3.micro"
  subnet_id                   = data.aws_subnet_ids.default.ids[0]
  vpc_security_group_ids      = [aws_security_group.app_sg.id]
  key_name                    = aws_key_pair.app_key.key_name
  associate_public_ip_address = true

  user_data = <<-EOF
    #!/bin/bash
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y python3-pip python3-venv git

    useradd -m appuser
    cd /home/appuser
    git clone https://your-git-repo-url/app.git
    cd app

    python3 -m venv venv
    . venv/bin/activate
    pip install --upgrade pip
    pip install -r requirements.txt

    cp .env.example .env || true

    chown -R appuser:appuser /home/appuser/app

    cat << EOT > /etc/systemd/system/fastapi-app.service
    [Unit]
    Description=FastAPI Service
    After=network.target
    [Service]
    User=appuser
    Group=appuser
    WorkingDirectory=/home/appuser/app
    ExecStart=/home/appuser/app/venv/bin/uvicorn backend.main:app --host 0.0.0.0 --port 8000
    EnvironmentFile=/home/appuser/app/.env
    Restart=always
    [Install]
    WantedBy=multi-user.target
    EOT

    systemctl daemon-reload
    systemctl enable fastapi-app
    systemctl start fastapi-app
  EOF

  tags = {
    Name = "fastapi-app"
  }
}