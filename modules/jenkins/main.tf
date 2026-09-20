data "aws_ami" "latest_amazon_linux" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

resource "aws_security_group" "jenkins_sg" {
  name        = "jenkins-sg-${var.environment}"
  description = "Jenkins web UI and agent access"
  vpc_id      = var.vpc_id

  ingress {
    description = "Jenkins UI from admin IP only"
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    cidr_blocks = [var.admin_ip_cidr]
  }

  ingress {
    description = "TEMP - EC2 Instance Connect for troubleshooting"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["18.206.107.24/29"]
  }

  ingress {
  description = "TEMP - direct SSH from admin IP for troubleshooting"
  from_port   = 22
  to_port     = 22
  protocol    = "tcp"
  cidr_blocks = ["35.135.164.88/32"]
}
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name        = "jenkins-sg-${var.environment}"
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}

data "aws_iam_policy_document" "jenkins_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "jenkins_role" {
  name               = "jenkins-role-${var.environment}"
  assume_role_policy = data.aws_iam_policy_document.jenkins_assume_role.json

  tags = {
    Environment = var.environment
  }
}

# Broad for now — same as the OIDC role, tighten once the pipeline is proven out
data "aws_iam_policy_document" "jenkins_permissions" {
  statement {
    actions = [
      "s3:*",
      "ec2:*",
      "iam:*",
      "dynamodb:*",
    ]
    resources = ["*"]
  }

  statement {
    actions   = ["ssm:PutParameter", "ssm:GetParameter"]
    resources = ["arn:aws:ssm:us-east-1:*:parameter/jenkins/*"]
  }
}
resource "aws_iam_role_policy" "jenkins_policy" {
  name   = "jenkins-policy-${var.environment}"
  role   = aws_iam_role.jenkins_role.id
  policy = data.aws_iam_policy_document.jenkins_permissions.json
}

resource "aws_iam_role_policy_attachment" "jenkins_ssm" {
  role       = aws_iam_role.jenkins_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "jenkins_profile" {
  name = "jenkins-profile-${var.environment}"
  role = aws_iam_role.jenkins_role.name
}

resource "aws_instance" "jenkins" {
  ami                          = data.aws_ami.latest_amazon_linux.id
  instance_type                = var.instance_type
  subnet_id                    = var.subnet_id
  vpc_security_group_ids       = [aws_security_group.jenkins_sg.id]
  iam_instance_profile         = aws_iam_instance_profile.jenkins_profile.name
  associate_public_ip_address  = true
  key_name = aws_key_pair.jenkins.key_name
  user_data                    = file("${path.module}/scripts/install_jenkins.sh")
  user_data_replace_on_change  = true

  root_block_device {
    volume_size = 30
    volume_type = "gp3"
    encrypted   = true
  }

  tags = {
    Name        = "jenkins-${var.environment}"
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}

resource "tls_private_key" "jenkins" {
  algorithm = "ED25519"
}

resource "aws_key_pair" "jenkins" {
  key_name   = "jenkins-${var.environment}"
  public_key = tls_private_key.jenkins.public_key_openssh

  tags = {
    Environment = var.environment
  }
}

resource "local_sensitive_file" "jenkins_private_key" {
  content         = tls_private_key.jenkins.private_key_openssh
  filename        = "${path.module}/keys/jenkins_id_ed25519"
  file_permission = "0400"
}