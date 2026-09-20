output "api_base_url" {
  description = "Base URL for the deployed API."
  value       = aws_apigatewayv2_stage.default.invoke_url
}

output "passcode_endpoint" {
  description = "POST endpoint used by the iOS app."
  value       = "${trimsuffix(aws_apigatewayv2_stage.default.invoke_url, "/")}/v1/passcode"
}

output "dynamodb_table_name" {
  description = "Table containing expiring rate-limit and attestation records."
  value       = aws_dynamodb_table.requests.name
}

