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

resource "aws_instance" "app_server" {
  ami                          = data.aws_ami.latest_amazon_linux.id
  instance_type                = "t3.micro"
  iam_instance_profile         = var.instance_profile_name
  subnet_id                    = var.subnet_id
  vpc_security_group_ids       = [var.security_group_id]
  associate_public_ip_address  = true
  user_data                    = file("${path.module}/scripts/user_data_a.sh")

  depends_on = [var.route_table_association_id]

  tags = {
    Name        = "app-server-${var.environment}"
    Environment = var.environment
    ManagedBy   = var.managed_by
  }
}