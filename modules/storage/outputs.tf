output "bucket_name" {
  value = aws_s3_bucket.app_assets.id
}

output "bucket_arn" {
  value = aws_s3_bucket.app_assets.arn
}