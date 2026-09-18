terraform {
  backend "s3" {
    bucket         = "use-tfstate-1"
    key            = "staging/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "terraform-locks"
    encrypt        = true
  }
}