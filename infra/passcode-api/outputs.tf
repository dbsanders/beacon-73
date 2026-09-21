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
  description = "Table containing expiring rate-limit and attestation records."
  value       = aws_dynamodb_table.requests.name
}
