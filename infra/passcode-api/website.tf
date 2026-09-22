provider "aws" {
  alias               = "us_east_1"
  region              = "us-east-1"
  allowed_account_ids = [var.expected_account_id]
}

locals {
  website_bucket_name = "beacon73-website-${var.environment}-${var.expected_account_id}"
  website_content_types = {
    ".css"  = "text/css; charset=utf-8"
    ".html" = "text/html; charset=utf-8"
    ".png"  = "image/png"
    ".svg"  = "image/svg+xml"
  }
  website_files = fileset("${path.module}/../../website", "**")
}

resource "aws_s3_bucket" "site" {
  bucket = local.website_bucket_name

  tags = {
    Component = "Website"
  }
}

resource "aws_s3_bucket_public_access_block" "site" {
  bucket                  = aws_s3_bucket.site.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "site" {
  bucket = aws_s3_bucket.site.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_versioning" "site" {
  bucket = aws_s3_bucket.site.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "site" {
  bucket = aws_s3_bucket.site.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_cloudfront_origin_access_control" "site" {
  name                              = "beacon73-website"
  description                       = "Private S3 origin for beacon73.com"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

resource "aws_cloudfront_function" "directory_index" {
  name    = "beacon73-directory-index"
  runtime = "cloudfront-js-2.0"
  publish = true
  code    = <<-JS
    function handler(event) {
      var request = event.request;
      if (request.uri.endsWith('/')) {
        request.uri += 'index.html';
      } else if (!request.uri.split('/').pop().includes('.')) {
        request.uri += '/index.html';
      }
      return request;
    }
  JS

  tags = {
    Component = "Website"
  }
}

resource "aws_cloudfront_response_headers_policy" "security" {
  name = "beacon73-website-security"

  security_headers_config {
    content_security_policy {
      content_security_policy = "default-src 'self'; img-src 'self'; style-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'; upgrade-insecure-requests"
      override                = true
    }
    content_type_options {
      override = true
    }
    frame_options {
      frame_option = "DENY"
      override     = true
    }
    referrer_policy {
      referrer_policy = "strict-origin-when-cross-origin"
      override        = true
    }
    strict_transport_security {
      access_control_max_age_sec = 31536000
      include_subdomains         = true
      preload                    = true
      override                   = true
    }
    xss_protection {
      mode_block = true
      protection = true
      override   = true
    }
  }

  custom_headers_config {
    items {
      header   = "Permissions-Policy"
      value    = "camera=(), microphone=(), geolocation=()"
      override = true
    }
  }
}

resource "aws_acm_certificate" "site" {
  provider                  = aws.us_east_1
  domain_name               = var.website_domain_name
  subject_alternative_names = ["www.${var.website_domain_name}"]
  validation_method         = "DNS"

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_cloudfront_distribution" "site" {
  enabled             = true
  is_ipv6_enabled     = true
  comment             = "Beacon 73 public website"
  default_root_object = "index.html"
  price_class         = "PriceClass_100"
  aliases             = var.website_custom_domain_enabled ? [var.website_domain_name, "www.${var.website_domain_name}"] : []

  origin {
    domain_name              = aws_s3_bucket.site.bucket_regional_domain_name
    origin_id                = "s3-site"
    origin_access_control_id = aws_cloudfront_origin_access_control.site.id
  }

  default_cache_behavior {
    allowed_methods            = ["GET", "HEAD", "OPTIONS"]
    cached_methods             = ["GET", "HEAD"]
    target_origin_id           = "s3-site"
    viewer_protocol_policy     = "redirect-to-https"
    compress                   = true
    cache_policy_id            = "658327ea-f89d-4fab-a63d-7e88639e58f6"
    response_headers_policy_id = aws_cloudfront_response_headers_policy.security.id

    function_association {
      event_type   = "viewer-request"
      function_arn = aws_cloudfront_function.directory_index.arn
    }
  }

  custom_error_response {
    error_code            = 403
    response_code         = 404
    response_page_path    = "/404.html"
    error_caching_min_ttl = 60
  }

  custom_error_response {
    error_code            = 404
    response_code         = 404
    response_page_path    = "/404.html"
    error_caching_min_ttl = 60
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = var.website_custom_domain_enabled ? null : true
    acm_certificate_arn            = var.website_custom_domain_enabled ? aws_acm_certificate.site.arn : null
    ssl_support_method             = var.website_custom_domain_enabled ? "sni-only" : null
    minimum_protocol_version       = var.website_custom_domain_enabled ? "TLSv1.2_2021" : "TLSv1"
  }

  tags = {
    Component = "Website"
  }
}

resource "aws_s3_bucket_policy" "site" {
  bucket = aws_s3_bucket.site.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "AllowCloudFrontRead"
      Effect    = "Allow"
      Principal = { Service = "cloudfront.amazonaws.com" }
      Action    = "s3:GetObject"
      Resource  = "${aws_s3_bucket.site.arn}/*"
      Condition = { StringEquals = { "AWS:SourceArn" = aws_cloudfront_distribution.site.arn } }
    }]
  })
}

resource "aws_s3_object" "site" {
  for_each = local.website_files

  bucket        = aws_s3_bucket.site.id
  key           = each.value
  source        = "${path.module}/../../website/${each.value}"
  source_hash   = filemd5("${path.module}/../../website/${each.value}")
  content_type  = lookup(local.website_content_types, regex("\\.[^.]+$", each.value), "application/octet-stream")
  cache_control = endswith(each.value, ".html") ? "public, max-age=300" : "public, max-age=86400"

  tags = {
    Component = "Website"
  }

  depends_on = [aws_s3_bucket_ownership_controls.site]
}
