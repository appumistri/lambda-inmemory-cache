terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "5.30.0"
    }
  }
}

provider "aws" {
  region  = var.region
  profile = var.profile
}

## S3 ##

# resource "random_pet" "lambda_bucket_name" {
#   prefix = "learn-terraform-functions"
#   length = 4
# }

resource "aws_s3_bucket" "lambda_bucket" {
  bucket = "appu-test-lambda-bucket-${var.stage}"
}

resource "aws_s3_bucket_ownership_controls" "lambda_bucket" {
  bucket = aws_s3_bucket.lambda_bucket.id
  rule {
    object_ownership = "BucketOwnerPreferred"
  }
}

resource "aws_s3_bucket_acl" "lambda_bucket" {
  depends_on = [aws_s3_bucket_ownership_controls.lambda_bucket]

  bucket = aws_s3_bucket.lambda_bucket.id
  acl    = "private"
}

## Lambda ##

data "archive_file" "lambda_hello_world" {
  type = "zip"

  source_dir  = "${path.module}/src"
  output_path = "${path.module}/test_service.zip"
}

resource "aws_s3_object" "lambda_hello_world" {
  bucket = aws_s3_bucket.lambda_bucket.id

  key    = "test_service.zip"
  source = data.archive_file.lambda_hello_world.output_path

  etag = filemd5(data.archive_file.lambda_hello_world.output_path)
}

resource "aws_lambda_function" "hello_world" {
  function_name = "test-lambda-${var.stage}"

  s3_bucket = aws_s3_bucket.lambda_bucket.id
  s3_key    = aws_s3_object.lambda_hello_world.key

  runtime = "nodejs20.x"
  handler = "index.handler"

  source_code_hash = data.archive_file.lambda_hello_world.output_base64sha256

  role = aws_iam_role.lambda_exec.arn
}

resource "aws_cloudwatch_log_group" "hello_world" {
  name = "/aws/lambda/${aws_lambda_function.hello_world.function_name}"

  retention_in_days = 30
}

resource "aws_iam_role" "lambda_exec" {
  name = "test-lambda-role-${var.stage}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Sid    = ""
        Principal = {
          Service = "lambda.amazonaws.com"
        }
      },
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Sid    = ""
        Principal = {
          Service = "scheduler.amazonaws.com"
        }
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_policy" {
  role       = aws_iam_role.lambda_exec.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_lambda_permission" "lambda_permission" {
  statement_id  = "AllowMyDemoAPIInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.hello_world.function_name
  principal     = "apigateway.amazonaws.com"

  # The /* part allows invocation from any stage, method and resource path
  # within API Gateway.
  source_arn = "${aws_api_gateway_rest_api.test_api.execution_arn}/*"
}

# output "function_name" {
#   description = "Name of the Lambda function."

#   value = aws_lambda_function.hello_world.function_name
# }


## cloudwatch schedule event ##

resource "aws_scheduler_schedule" "lambda_warmer" {
  name       = "test-lambda-warmer-${var.stage}"
  group_name = "default"

  flexible_time_window {
    mode = "OFF"
  }

  schedule_expression = "rate(2 minutes)"

  target {
    arn      = aws_lambda_function.hello_world.arn
    role_arn = aws_iam_role.lambda_exec.arn
    input = jsonencode({
      source = "event-bridge"
    })
  }
}

## API Gateway ##

resource "aws_api_gateway_rest_api" "test_api" {
  name = "test-api-${var.stage}"
  endpoint_configuration {
    types = ["REGIONAL"]
  }
}

resource "aws_api_gateway_resource" "apig" {
  parent_id   = aws_api_gateway_rest_api.test_api.root_resource_id
  path_part   = var.stage
  rest_api_id = aws_api_gateway_rest_api.test_api.id
}

resource "aws_api_gateway_method" "apig_method" {
  authorization = "NONE"
  http_method   = "GET"
  resource_id   = aws_api_gateway_resource.apig.id
  rest_api_id   = aws_api_gateway_rest_api.test_api.id
}

resource "aws_api_gateway_integration" "apig_intg" {
  http_method             = aws_api_gateway_method.apig_method.http_method
  resource_id             = aws_api_gateway_resource.apig.id
  rest_api_id             = aws_api_gateway_rest_api.test_api.id
  type                    = "AWS_PROXY"
  integration_http_method = "POST"
  timeout_milliseconds    = 5000
  uri                     = aws_lambda_function.hello_world.invoke_arn
}

resource "aws_api_gateway_deployment" "apig_deploy" {
  rest_api_id = aws_api_gateway_rest_api.test_api.id

  triggers = {
    # NOTE: The configuration below will satisfy ordering considerations,
    #       but not pick up all future REST API changes. More advanced patterns
    #       are possible, such as using the filesha1() function against the
    #       Terraform configuration file(s) or removing the .id references to
    #       calculate a hash against whole resources. Be aware that using whole
    #       resources will show a difference after the initial implementation.
    #       It will stabilize to only change when resources change afterwards.
    redeployment = sha1(jsonencode([
      aws_api_gateway_resource.apig.id,
      aws_api_gateway_method.apig_method.id,
      aws_api_gateway_integration.apig_intg.id,
    ]))
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_api_gateway_stage" "apig_stage" {
  deployment_id = aws_api_gateway_deployment.apig_deploy.id
  rest_api_id   = aws_api_gateway_rest_api.test_api.id
  stage_name    = var.stage
}

output "api_invoke_url" {
  value = aws_api_gateway_stage.apig_stage.invoke_url
}
