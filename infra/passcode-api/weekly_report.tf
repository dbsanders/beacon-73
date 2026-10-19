data "archive_file" "weekly_report" {
  type        = "zip"
  source_file = "${path.module}/backend/weekly_report.py"
  output_path = "${path.module}/.terraform/${local.name}-weekly-report.zip"
}

resource "aws_sns_topic" "weekly_report" {
  name = "${local.name}-weekly-callsign-report"
}

resource "aws_sns_topic_subscription" "weekly_report_email" {
  topic_arn = aws_sns_topic.weekly_report.arn
  protocol  = "email"
  endpoint  = var.weekly_report_email
}

resource "aws_iam_role" "weekly_report" {
  name = "${local.name}-weekly-report"

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

resource "aws_iam_role_policy" "weekly_report" {
  name = "${local.name}-weekly-report"
  role = aws_iam_role.weekly_report.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ReadAndRetainUniqueCallsigns"
        Effect   = "Allow"
        Action   = ["dynamodb:Scan", "dynamodb:UpdateItem"]
        Resource = aws_dynamodb_table.requests.arn
      },
      {
        Sid      = "PublishWeeklyReport"
        Effect   = "Allow"
        Action   = ["sns:Publish"]
        Resource = aws_sns_topic.weekly_report.arn
      },
      {
        Sid    = "ReadFccReportingData"
        Effect = "Allow"
        Action = ["s3:GetObject"]
        Resource = [
          "${aws_s3_bucket.fcc_data.arn}/current/*",
          "${aws_s3_bucket.fcc_data.arn}/datasets/*"
        ]
      },
      {
        Sid    = "WriteFunctionLogs"
        Effect = "Allow"
        Action = [
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "${aws_cloudwatch_log_group.weekly_report.arn}:*"
      }
    ]
  })
}

resource "aws_cloudwatch_log_group" "weekly_report" {
  name              = "/aws/lambda/${local.name}-weekly-report"
  retention_in_days = var.log_retention_days
}

resource "aws_lambda_function" "weekly_report" {
  function_name = "${local.name}-weekly-report"
  description   = "Emails new passcode-request callsigns and the running unique total."
  role          = aws_iam_role.weekly_report.arn
  handler       = "weekly_report.lambda_handler"
  runtime       = "python3.12"
  architectures = ["arm64"]
  memory_size   = 256
  timeout       = 30

  filename         = data.archive_file.weekly_report.output_path
  source_code_hash = data.archive_file.weekly_report.output_base64sha256

  environment {
    variables = {
      TABLE_NAME       = aws_dynamodb_table.requests.name
      REPORT_TOPIC_ARN = aws_sns_topic.weekly_report.arn
      REPORT_TIME_ZONE = var.weekly_report_time_zone
      HASH_SALT        = random_password.hash_salt.result
      FCC_BUCKET_NAME  = aws_s3_bucket.fcc_data.id
    }
  }

  depends_on = [
    aws_cloudwatch_log_group.weekly_report,
    aws_iam_role_policy.weekly_report
  ]
}

resource "aws_iam_role" "weekly_report_scheduler" {
  name = "${local.name}-weekly-report-scheduler"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "scheduler.amazonaws.com"
      }
      Action = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "weekly_report_scheduler" {
  name = "${local.name}-weekly-report-scheduler"
  role = aws_iam_role.weekly_report_scheduler.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["lambda:InvokeFunction"]
      Resource = aws_lambda_function.weekly_report.arn
    }]
  })
}

resource "aws_scheduler_schedule" "weekly_report" {
  name                         = "${local.name}-weekly-report"
  description                  = "Send the weekly passcode callsign report every Monday morning."
  schedule_expression          = "cron(0 9 ? * MON *)"
  schedule_expression_timezone = var.weekly_report_time_zone

  flexible_time_window {
    mode = "OFF"
  }

  target {
    arn      = aws_lambda_function.weekly_report.arn
    role_arn = aws_iam_role.weekly_report_scheduler.arn

    retry_policy {
      maximum_event_age_in_seconds = 3600
      maximum_retry_attempts       = 2
    }
  }
}
