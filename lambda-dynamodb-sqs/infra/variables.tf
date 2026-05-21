variable "region" {
  type    = string
  default = "us-east-1"
}

variable "lambda_function_name" {
  description = "Lambda + ECR repo name."
  type        = string
  default     = "aws-gleam-lambda-dynamodb-sqs"
}

variable "queue_name" {
  description = "SQS queue name."
  type        = string
  default     = "aws-gleam-lambda-dynamodb-sqs-ingress"
}

variable "table_name" {
  description = "DynamoDB table name. Hash key is `user_id`."
  type        = string
  default     = "aws-gleam-lambda-dynamodb-sqs-users"
}

variable "image_tag" {
  description = <<-EOT
    ECR image tag the Lambda points at. The Lambda pins to the
    digest behind whichever tag is set here, so a fresh push
    automatically rolls the function forward.
  EOT
  type    = string
  default = "latest"
}
