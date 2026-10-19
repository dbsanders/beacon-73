output "api_base_url" {
  description = "Base URL for the deployed API."
  value       = aws_apigatewayv2_stage.default.invoke_url
}

output "passcode_endpoint" {
  description = "POST endpoint used by the iOS app."
  value       = "${trimsuffix(aws_apigatewayv2_stage.default.invoke_url, "/")}/v1/passcode"
}

output "callsign_lookup_endpoint_template" {
  description = "GET endpoint template used to look up an FCC callsign record."
  value       = "${trimsuffix(aws_apigatewayv2_stage.default.invoke_url, "/")}/v1/callsigns/{callsign}"
}

output "fcc_data_bucket_name" {
  description = "Private bucket containing raw and processed FCC datasets."
  value       = aws_s3_bucket.fcc_data.id
}

output "fcc_importer_function_name" {
  description = "Lambda function to invoke for an immediate FCC dataset refresh."
  value       = aws_lambda_function.fcc_importer.function_name
}

output "fcc_import_github_role_arn" {
  description = "AWS role assumed by the repository's weekly FCC import workflow."
  value       = aws_iam_role.github_fcc_import.arn
}

output "dynamodb_table_name" {
  description = "Table containing expiring request records and retained unique-callsign records."
  value       = aws_dynamodb_table.requests.name
}

output "weekly_report_function_name" {
  description = "Lambda function that sends the weekly passcode callsign report."
  value       = aws_lambda_function.weekly_report.function_name
}

output "weekly_report_topic_arn" {
  description = "SNS topic used to deliver the weekly passcode callsign report."
  value       = aws_sns_topic.weekly_report.arn
}

output "website_bucket_name" {
  description = "Private S3 bucket containing the Beacon 73 website."
  value       = aws_s3_bucket.site.id
}

output "website_cloudfront_distribution_id" {
  description = "CloudFront distribution serving the Beacon 73 website."
  value       = aws_cloudfront_distribution.site.id
}

output "website_cloudfront_domain_name" {
  description = "CloudFront hostname behind the Beacon 73 public domain."
  value       = aws_cloudfront_distribution.site.domain_name
}

output "website_certificate_arn" {
  description = "ACM certificate used by the Beacon 73 website."
  value       = aws_acm_certificate.site.arn
}

output "website_certificate_validation_records" {
  description = "DNS records required to validate the website certificate."
  value = {
    for option in aws_acm_certificate.site.domain_validation_options : option.domain_name => {
      name  = option.resource_record_name
      type  = option.resource_record_type
      value = option.resource_record_value
    }
  }
}
