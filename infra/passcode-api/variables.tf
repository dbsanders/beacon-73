variable "aws_region" {
  description = "AWS region in which to deploy the API."
  type        = string
  default     = "us-west-2"
}

variable "expected_account_id" {
  description = "AWS account that is allowed to host the production stack."
  type        = string
  default     = "422095364378"

  validation {
    condition     = can(regex("^[0-9]{12}$", var.expected_account_id))
    error_message = "expected_account_id must be a 12-digit AWS account ID."
  }
}

variable "environment" {
  description = "Short environment name used in resource names and tags."
  type        = string
  default     = "prod"

  validation {
    condition     = can(regex("^[a-z0-9-]{1,16}$", var.environment))
    error_message = "environment must be 1-16 lowercase letters, digits, or hyphens."
  }
}

variable "website_domain_name" {
  description = "Primary public domain for the Beacon 73 website."
  type        = string
  default     = "beacon73.com"
}

variable "website_custom_domain_enabled" {
  description = "Whether CloudFront serves the website on its public domain aliases."
  type        = bool
  default     = true
}

variable "rate_limit_requests" {
  description = "Maximum successful attempts per source IP in each fixed window."
  type        = number
  default     = 5

  validation {
    condition     = var.rate_limit_requests >= 1 && floor(var.rate_limit_requests) == var.rate_limit_requests
    error_message = "rate_limit_requests must be a positive whole number."
  }
}

variable "rate_limit_window_seconds" {
  description = "Length of the application-level fixed rate-limit window."
  type        = number
  default     = 3600

  validation {
    condition     = var.rate_limit_window_seconds >= 1 && floor(var.rate_limit_window_seconds) == var.rate_limit_window_seconds
    error_message = "rate_limit_window_seconds must be a positive whole number."
  }
}

variable "lookup_rate_limit_requests" {
  description = "Maximum FCC callsign lookups per source IP in each fixed window."
  type        = number
  default     = 30

  validation {
    condition     = var.lookup_rate_limit_requests >= 1 && floor(var.lookup_rate_limit_requests) == var.lookup_rate_limit_requests
    error_message = "lookup_rate_limit_requests must be a positive whole number."
  }
}

variable "attestation_retention_days" {
  description = "Days to retain attestation audit records before DynamoDB TTL expiry."
  type        = number
  default     = 90

  validation {
    condition     = var.attestation_retention_days >= 1 && floor(var.attestation_retention_days) == var.attestation_retention_days
    error_message = "attestation_retention_days must be a positive whole number."
  }
}

variable "api_throttling_rate_limit" {
  description = "API Gateway steady-state requests per second across this stage."
  type        = number
  default     = 10

  validation {
    condition     = var.api_throttling_rate_limit > 0
    error_message = "api_throttling_rate_limit must be greater than zero."
  }
}

variable "api_throttling_burst_limit" {
  description = "API Gateway burst capacity across this stage."
  type        = number
  default     = 20

  validation {
    condition     = var.api_throttling_burst_limit >= 1 && floor(var.api_throttling_burst_limit) == var.api_throttling_burst_limit
    error_message = "api_throttling_burst_limit must be a positive whole number."
  }
}

variable "log_retention_days" {
  description = "CloudWatch log retention period."
  type        = number
  default     = 30

  validation {
    condition = contains([
      1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545,
      731, 1096, 1827, 2192, 2557, 2922, 3288, 3653
    ], var.log_retention_days)
    error_message = "log_retention_days must be a CloudWatch Logs-supported retention value."
  }
}

variable "weekly_report_email" {
  description = "Email address subscribed to the weekly passcode callsign report."
  type        = string
  default     = "support@beacon73.com"

  validation {
    condition     = can(regex("^[^@[:space:]]+@[^@[:space:]]+\\.[^@[:space:]]+$", var.weekly_report_email))
    error_message = "weekly_report_email must be a valid email address."
  }
}

variable "weekly_report_time_zone" {
  description = "IANA time zone used for the Monday report schedule and reporting period."
  type        = string
  default     = "America/Los_Angeles"
}

variable "tags" {
  description = "Additional tags applied to AWS resources."
  type        = map(string)
  default     = {}
}
