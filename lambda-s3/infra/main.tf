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

# ---- S3 bucket the Lambda writes each payload into ----

resource "aws_s3_bucket" "events" {
  bucket        = var.bucket_name
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "events" {
  bucket                  = aws_s3_bucket.events.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "events" {
  bucket = aws_s3_bucket.events.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
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
  # The handler PutObject-s each invocation payload under events/.
  # Scoped to that prefix — keep it in step with the key prefix in
  # src/lambda_s3.gleam if you change it.
  statement {
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.events.arn}/events/*"]
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
      BUCKET_NAME = aws_s3_bucket.events.bucket
    }
  }

  depends_on = [
    aws_iam_role_policy_attachment.lambda_basic,
    aws_iam_role_policy.lambda_perms,
    aws_cloudwatch_log_group.lambda,
  ]
}
