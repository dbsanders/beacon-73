data "aws_caller_identity" "current" {}

resource "aws_s3_bucket" "fcc_data" {
  bucket        = "beacon73-fcc-data-${data.aws_caller_identity.current.account_id}-${var.aws_region}"
  force_destroy = false
}

resource "aws_s3_bucket_public_access_block" "fcc_data" {
  bucket = aws_s3_bucket.fcc_data.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "fcc_data" {
  bucket = aws_s3_bucket.fcc_data.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_versioning" "fcc_data" {
  bucket = aws_s3_bucket.fcc_data.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "fcc_data" {
  bucket = aws_s3_bucket.fcc_data.id

  rule {
    id     = "expire-old-imports"
    status = "Enabled"

    filter {
      prefix = "imports/"
    }

    expiration {
      days = 35
    }

    noncurrent_version_expiration {
      noncurrent_days = 7
    }
  }

  rule {
    id     = "expire-old-processed-datasets"
    status = "Enabled"

    filter {
      prefix = "datasets/"
    }

    expiration {
      # Preserve the last good lookup data through an extended FCC outage.
      days = 180
    }

    noncurrent_version_expiration {
      noncurrent_days = 7
    }
  }

  rule {
    id     = "expire-old-manifest-versions"
    status = "Enabled"

    filter {
      prefix = "current/"
    }

    noncurrent_version_expiration {
      noncurrent_days = 35
    }
  }

  depends_on = [aws_s3_bucket_versioning.fcc_data]
}

data "archive_file" "fcc_importer" {
  type        = "zip"
  source_file = "${path.module}/backend/fcc_importer.py"
  output_path = "${path.module}/.terraform/${local.name}-fcc-importer.zip"
}

resource "aws_iam_role" "fcc_importer" {
  name = "${local.name}-fcc-importer"

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

resource "aws_iam_role_policy" "fcc_importer" {
  name = "${local.name}-fcc-importer"
  role = aws_iam_role.fcc_importer.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "PublishFccDataset"
        Effect = "Allow"
        Action = ["s3:PutObject"]
        Resource = [
          "${aws_s3_bucket.fcc_data.arn}/datasets/*",
          "${aws_s3_bucket.fcc_data.arn}/current/*"
        ]
      },
      {
        Sid      = "ReadFccImport"
        Effect   = "Allow"
        Action   = ["s3:GetObject"]
        Resource = "${aws_s3_bucket.fcc_data.arn}/imports/*"
      },
      {
        Sid    = "WriteImporterLogs"
        Effect = "Allow"
        Action = [
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "${aws_cloudwatch_log_group.fcc_importer.arn}:*"
      }
    ]
  })
}

resource "aws_cloudwatch_log_group" "fcc_importer" {
  name              = "/aws/lambda/${local.name}-fcc-importer"
  retention_in_days = var.log_retention_days
}

resource "aws_lambda_function" "fcc_importer" {
  function_name = "${local.name}-fcc-importer"
  description   = "Builds Beacon 73 callsign indexes from official FCC and ISED data."
  role          = aws_iam_role.fcc_importer.arn
  handler       = "fcc_importer.lambda_handler"
  runtime       = "python3.12"
  architectures = ["arm64"]
  memory_size   = 2048
  timeout       = 900

  ephemeral_storage {
    size = 2048
  }

  filename         = data.archive_file.fcc_importer.output_path
  source_code_hash = data.archive_file.fcc_importer.output_base64sha256

  environment {
    variables = {
      BUCKET_NAME = aws_s3_bucket.fcc_data.id
    }
  }

  depends_on = [
    aws_cloudwatch_log_group.fcc_importer,
    aws_iam_role_policy.fcc_importer
  ]
}

data "tls_certificate" "github_actions" {
  url = "https://token.actions.githubusercontent.com"
}

resource "aws_iam_openid_connect_provider" "github_actions" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.github_actions.certificates[0].sha1_fingerprint]
}

resource "aws_iam_role" "github_fcc_import" {
  name = "${local.name}-github-fcc-import"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Federated = aws_iam_openid_connect_provider.github_actions.arn
      }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          # GitHub's immutable subject includes the owner and repository IDs.
          "token.actions.githubusercontent.com:sub" = "repo:dbsanders@21073778/beacon-73@1378536487:ref:refs/heads/main"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy" "github_fcc_import" {
  name = "${local.name}-github-fcc-import"
  role = aws_iam_role.github_fcc_import.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "UploadFccArchive"
        Effect   = "Allow"
        Action   = ["s3:PutObject"]
        Resource = "${aws_s3_bucket.fcc_data.arn}/imports/*"
      },
      {
        Sid      = "InvokeFccImporter"
        Effect   = "Allow"
        Action   = ["lambda:InvokeFunction"]
        Resource = aws_lambda_function.fcc_importer.arn
      }
    ]
  })
}

resource "aws_cloudwatch_metric_alarm" "fcc_import_errors" {
  alarm_name          = "${local.name}-fcc-import-errors"
  alarm_description   = "A scheduled callsign registry import failed."
  namespace           = "AWS/Lambda"
  metric_name         = "Errors"
  statistic           = "Sum"
  period              = 900
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    FunctionName = aws_lambda_function.fcc_importer.function_name
  }
}
