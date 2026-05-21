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
  description = "Pass to `aws lambda invoke` (or just send to the queue)."
}

output "queue_url" {
  value       = aws_sqs_queue.ingress.url
  description = "Send messages here; Lambda triggers automatically."
}

output "queue_arn" {
  value = aws_sqs_queue.ingress.arn
}

output "table_name" {
  value       = aws_dynamodb_table.users.name
  description = "DynamoDB table the Lambda writes rows into."
}

output "log_group" {
  value       = aws_cloudwatch_log_group.lambda.name
  description = "CloudWatch log group. Tail with `aws logs tail <this> --follow`."
}
