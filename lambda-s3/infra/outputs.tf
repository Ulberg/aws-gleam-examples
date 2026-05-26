output "ecr_repo_url" {
  value       = aws_ecr_repository.lambda.repository_url
  description = "Where build.sh pushes the container image."
}

output "region" {
  value       = var.region
  description = "AWS region everything is deployed in."
}

output "lambda_function_name" {
  value       = aws_lambda_function.main.function_name
  description = "Pass to `aws lambda invoke --function-name`."
}

output "bucket_name" {
  value       = aws_s3_bucket.events.bucket
  description = "S3 bucket the Lambda writes payloads into (under events/)."
}

output "log_group" {
  value       = aws_cloudwatch_log_group.lambda.name
  description = "CloudWatch log group. Tail with `aws logs tail <this> --follow`."
}
