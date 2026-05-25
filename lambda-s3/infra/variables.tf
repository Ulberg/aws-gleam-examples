variable "region" {
  type    = string
  default = "us-east-1"
}

variable "lambda_function_name" {
  description = "Lambda + ECR repo name."
  type        = string
  default     = "aws-gleam-lambda-s3"
}

variable "bucket_name" {
  description = <<-EOT
    S3 bucket the Lambda writes payloads into. Must be globally
    unique across all of S3 — prefix with your AWS account id or a
    personal handle. No default; set it in terraform.tfvars.
  EOT
  type = string
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
