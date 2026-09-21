provider "aws" {
  region = var.aws_region

  allowed_account_ids = [var.expected_account_id]

  default_tags {
    tags = merge({
      Application = "Beacon73"
      Environment = var.environment
      ManagedBy   = "Terraform"
    }, var.tags)
  }
}

locals {
  name = "beacon73-passcode-${var.environment}"
}

resource "random_password" "hash_salt" {
  length  = 32
  special = false
}

resource "aws_dynamodb_table" "requests" {
  name         = "${local.name}-requests"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "pk"

  attribute {
    name = "pk"
    type = "S"
  }

  point_in_time_recovery {
    enabled = true
  }

  server_side_encryption {
    enabled = true
  }

  ttl {
    attribute_name = "expires_at"
    enabled        = true
  }
}

data "archive_file" "lambda" {
  type        = "zip"
  source_file = "${path.module}/backend/app.py"
  output_path = "${path.module}/.terraform/${local.name}.zip"
}

resource "aws_iam_role" "lambda" {
  name = "${local.name}-lambda"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "lambda.amazonaws.com"
      }
      Action = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "lambda" {
  name = "${local.name}-lambda"
  role = aws_iam_role.lambda.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "WriteRequestRecords"
        Effect = "Allow"
        Action = [
          "dynamodb:PutItem",
          "dynamodb:UpdateItem"
        ]
        Resource = aws_dynamodb_table.requests.arn
      },
      {
        Sid    = "WriteFunctionLogs"
        Effect = "Allow"
        Action = [
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "${aws_cloudwatch_log_group.lambda.arn}:*"
      },
      {
        Sid    = "ReadFccCallsignIndex"
        Effect = "Allow"
        Action = ["s3:GetObject"]
        Resource = [
          "${aws_s3_bucket.fcc_data.arn}/current/*",
          "${aws_s3_bucket.fcc_data.arn}/datasets/*"
        ]
      }
    ]
  })
}

resource "aws_cloudwatch_log_group" "lambda" {
  name              = "/aws/lambda/${local.name}"
  retention_in_days = var.log_retention_days
}

resource "aws_lambda_function" "passcode" {
  function_name = local.name
  description   = "Validates an amateur callsign and issues its APRS-IS passcode."
  role          = aws_iam_role.lambda.arn
  handler       = "app.lambda_handler"
  runtime       = "python3.12"
  architectures = ["arm64"]
  memory_size   = 256
  timeout       = 10

  filename         = data.archive_file.lambda.output_path
  source_code_hash = data.archive_file.lambda.output_base64sha256

  environment {
    variables = {
      TABLE_NAME                 = aws_dynamodb_table.requests.name
      RATE_LIMIT_REQUESTS        = tostring(var.rate_limit_requests)
      RATE_LIMIT_WINDOW_SECONDS  = tostring(var.rate_limit_window_seconds)
      ATTESTATION_RETENTION_DAYS = tostring(var.attestation_retention_days)
      ATTESTATION_VERSION        = "v2"
      HASH_SALT                  = random_password.hash_salt.result
      FCC_BUCKET_NAME            = aws_s3_bucket.fcc_data.id
      LOOKUP_RATE_LIMIT_REQUESTS = tostring(var.lookup_rate_limit_requests)
    }
  }

  depends_on = [
    aws_cloudwatch_log_group.lambda,
    aws_iam_role_policy.lambda
  ]
}

resource "aws_cloudwatch_log_group" "api" {
  name              = "/aws/apigateway/${local.name}"
  retention_in_days = var.log_retention_days
}

resource "aws_apigatewayv2_api" "passcode" {
  name          = local.name
  protocol_type = "HTTP"
  description   = "Beacon 73 APRS-IS passcode request API"

  disable_execute_api_endpoint = false
}

resource "aws_apigatewayv2_integration" "lambda" {
  api_id                 = aws_apigatewayv2_api.passcode.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.passcode.invoke_arn
  payload_format_version = "2.0"
  timeout_milliseconds   = 10000
}

resource "aws_apigatewayv2_route" "request_passcode" {
  api_id    = aws_apigatewayv2_api.passcode.id
  route_key = "POST /v1/passcode"
  target    = "integrations/${aws_apigatewayv2_integration.lambda.id}"
}

resource "aws_apigatewayv2_route" "lookup_callsign" {
  api_id    = aws_apigatewayv2_api.passcode.id
  route_key = "GET /v1/callsigns/{callsign}"
  target    = "integrations/${aws_apigatewayv2_integration.lambda.id}"
}

resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.passcode.id
  name        = "$default"
  auto_deploy = true

  default_route_settings {
    detailed_metrics_enabled = true
    throttling_burst_limit   = var.api_throttling_burst_limit
    throttling_rate_limit    = var.api_throttling_rate_limit
  }

  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.api.arn
    format = jsonencode({
      requestId      = "$context.requestId"
      requestTime    = "$context.requestTime"
      routeKey       = "$context.routeKey"
      status         = "$context.status"
      responseLength = "$context.responseLength"
      integrationErr = "$context.integrationErrorMessage"
    })
  }
}

resource "aws_lambda_permission" "api_gateway" {
  statement_id  = "AllowApiGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.passcode.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.passcode.execution_arn}/*/*"
}
