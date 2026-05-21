terraform {
  required_version = ">= 1.6"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.50"
    }
  }
}

provider "aws" {
  region = var.region
}

# ---- DynamoDB table ----

resource "aws_dynamodb_table" "users" {
  name         = var.table_name
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "user_id"

  attribute {
    name = "user_id"
    type = "S"
  }
}

# ---- SQS queue ----

resource "aws_sqs_queue" "ingress" {
  name                       = var.queue_name
  message_retention_seconds  = 86400
  visibility_timeout_seconds = 60
}

# ---- ECR repo for the Lambda container image ----

resource "aws_ecr_repository" "lambda" {
  name                 = var.lambda_function_name
  force_delete         = true
  image_tag_mutability = "MUTABLE"
}

data "aws_ecr_image" "lambda" {
  repository_name = aws_ecr_repository.lambda.name
  image_tag       = var.image_tag
  depends_on      = [aws_ecr_repository.lambda]
}

# ---- IAM ----

data "aws_iam_policy_document" "lambda_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "lambda" {
  name               = "${var.lambda_function_name}-exec"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

resource "aws_iam_role_policy_attachment" "lambda_basic" {
  role       = aws_iam_role.lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

data "aws_iam_policy_document" "lambda_perms" {
  # SQS event source mapping: Lambda polls the queue + deletes on
  # success. Scoped to this queue's ARN.
  statement {
    actions = [
      "sqs:ReceiveMessage",
      "sqs:DeleteMessage",
      "sqs:GetQueueAttributes",
    ]
    resources = [aws_sqs_queue.ingress.arn]
  }
  # DynamoDB: PutItem on the table. PutItem creates rows; the
  # event-source mapping doesn't need the queue's scan/query
  # permissions.
  statement {
    actions   = ["dynamodb:PutItem"]
    resources = [aws_dynamodb_table.users.arn]
  }
}

resource "aws_iam_role_policy" "lambda_perms" {
  name   = "${var.lambda_function_name}-perms"
  role   = aws_iam_role.lambda.id
  policy = data.aws_iam_policy_document.lambda_perms.json
}

# ---- CloudWatch log group ----

resource "aws_cloudwatch_log_group" "lambda" {
  name              = "/aws/lambda/${var.lambda_function_name}"
  retention_in_days = 7
}

# ---- Lambda function ----

locals {
  image_uri = "${aws_ecr_repository.lambda.repository_url}@${data.aws_ecr_image.lambda.image_digest}"
}

resource "aws_lambda_function" "main" {
  function_name = var.lambda_function_name
  role          = aws_iam_role.lambda.arn

  package_type = "Image"
  image_uri    = local.image_uri

  memory_size = 512
  timeout     = 30

  # Match the image's --platform linux/arm64 (build.sh).
  architectures = ["arm64"]

  environment {
    variables = {
      TABLE_NAME = aws_dynamodb_table.users.name
    }
  }

  depends_on = [
    aws_iam_role_policy_attachment.lambda_basic,
    aws_iam_role_policy.lambda_perms,
    aws_cloudwatch_log_group.lambda,
  ]
}

# SQS → Lambda event source mapping.
# `function_response_types = ["ReportBatchItemFailures"]` enables
# the partial-batch failure path: the Lambda returns
# `{ "batchItemFailures": [...] }` listing failed message IDs;
# only those redrive, the rest are deleted.
resource "aws_lambda_event_source_mapping" "sqs" {
  event_source_arn        = aws_sqs_queue.ingress.arn
  function_name           = aws_lambda_function.main.arn
  batch_size              = 10
  function_response_types = ["ReportBatchItemFailures"]
}
