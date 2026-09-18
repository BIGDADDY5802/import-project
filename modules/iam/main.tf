# Trust policy: only EC2 instances can assume this role
data "aws_iam_policy_document" "assume_role" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "app_role" {
  name               = "app-role-${var.environment}"
  assume_role_policy = data.aws_iam_policy_document.assume_role.json

  tags = {
    Environment = var.environment
  }
}

# Scoped policy: only what the app actually needs — read/write to its own bucket
data "aws_iam_policy_document" "app_policy" {
  statement {
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:ListBucket",
    ]
    resources = [
      var.app_assets_bucket_arn,
      "${var.app_assets_bucket_arn}/*",
    ]
  }
}

resource "aws_iam_role_policy" "app_policy" {
  name   = "app-policy-${var.environment}"
  role   = aws_iam_role.app_role.id
  policy = data.aws_iam_policy_document.app_policy.json
}

resource "aws_iam_instance_profile" "app_profile" {
  name = "app-profile-${var.environment}"
  role = aws_iam_role.app_role.name
}