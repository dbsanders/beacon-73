# Beacon 73 APRS-IS passcode API

This project deploys a small, serverless AWS API for Beacon 73. The iOS app sends a callsign and an explicit license attestation; the API normalizes and validates the callsign, rate-limits the source, records the attestation, computes the deterministic APRS-IS passcode, and returns it. Passcodes are never stored or logged.

## Architecture

- **API Gateway HTTP API** exposes `POST /v1/passcode` and applies a stage-wide burst/rate ceiling.
- **Lambda (Python 3.12, arm64)** validates requests and calculates the passcode.
- **DynamoDB on-demand** stores short-lived rate counters and attestation audit records in one encrypted table.
- **CloudWatch Logs** retains structured Lambda and API access logs for 30 days by default. Access logs omit request bodies and source IPs.

There are no always-on servers. For a small app, the AWS usage should generally remain within or near serverless free-tier levels, depending on traffic and account eligibility. DynamoDB point-in-time recovery is enabled as a secure default and may add a small charge.

## API contract

The app should display this text next to an unchecked control:

> I attest that I am a licensed amateur-radio operator authorized to use this callsign.

Only send the request after the user actively accepts it:

```http
POST /v1/passcode
Content-Type: application/json

{"callsign":"K6BAT-7","attestation":true}
```

Successful response:

```json
{"callsign":"K6BAT","passcode":12345,"attestationRecorded":true}
```

The numeric value above is illustrative. Do not include callsigns or passcodes in client analytics or diagnostic logs. Treat the returned passcode as sensitive app configuration and store it in the iOS Keychain if it must be retained locally.

Errors have a stable shape and use HTTP `400`, `413`, `429`, or `500` as appropriate:

```json
{"error":{"code":"invalid_callsign","message":"callsign format is not accepted"}}
```

## What is recorded

Each accepted request creates an attestation record containing the normalized callsign, attestation version, time, and keyed hashes of the source IP and user agent. The raw source IP, raw user agent, and passcode are not stored. Attestation records expire after 90 days by default. DynamoDB TTL deletion is asynchronous, so AWS may retain an expired record briefly after its expiration timestamp.

Rate-limit entries use only a keyed source-IP hash and fixed-window timestamp. They expire after the window plus a one-day cleanup buffer. The default application limit is 5 accepted attempts per source IP per hour. Invalid requests that fail before callsign validation do not consume this quota; API Gateway still protects the service-wide request rate.

## Prerequisites

- Terraform 1.6 or newer
- AWS credentials with permission to create API Gateway, Lambda, DynamoDB, IAM role/policy, and CloudWatch Logs resources
- Python 3.12 for local tests

Use a remote Terraform backend with encryption and access controls for team or production deployments. Terraform state contains the generated HMAC salt used to pseudonymize network identifiers.

## Deploy

```sh
aws sts get-caller-identity
terraform init
terraform plan -out=tfplan
terraform apply tfplan
terraform output -raw passcode_endpoint
```

You can override defaults in `terraform.tfvars`:

```hcl
aws_region                 = "us-west-2"
environment                = "prod"
rate_limit_requests        = 5
rate_limit_window_seconds  = 3600
attestation_retention_days = 90
log_retention_days         = 30
```

Smoke-test the deployed endpoint:

```sh
curl --fail-with-body \
  -H 'content-type: application/json' \
  --data '{"callsign":"K6BAT-7","attestation":true}' \
  "$(terraform output -raw passcode_endpoint)"
```

Destroy the development stack when no longer needed:

```sh
terraform destroy
```

## Local tests

Lambda includes `boto3`, but a local Python environment may not. Install the development dependency and run the standard-library test suite:

```sh
python3 -m venv .venv
. .venv/bin/activate
python -m pip install -r backend/requirements-dev.txt
python -m unittest discover -s backend -p 'test_*.py'
```

## Security and privacy notes

- The Lambda role can only write items to this stack's DynamoDB table and its own log group.
- API responses disable caching. Logs contain request IDs, result codes, and keyed hashes only—not request bodies, raw IP addresses, callsigns, or passcodes.
- The callsign validator is intentionally conservative and based on APRS-IS international syntax guidance. It validates syntax, not license ownership or status.
- A deterministic APRS-IS passcode is not a strong authentication secret. This endpoint's controls are intended to discourage anonymous bulk generation and record the user's attestation.
- API Gateway throttling is best-effort and account/region quotas also apply. The DynamoDB conditional update enforces the per-source application limit atomically.

## Planned extension points

### Apple App Attest

Add an App Attest assertion and key ID to the request. Verify the assertion before `consume_rate_limit`, with keys/challenge state in a separate DynamoDB table or a dedicated verification service. Once enforced, increase confidence that requests originate from a genuine Beacon 73 installation. Keep a short migration period if old app versions must continue working.

### Optional FCC validation

Insert a country/authority validation step after syntax validation and before passcode generation. For U.S. callsigns, query an FCC-backed service, cache only the active/inactive result for a bounded period, and fail safely when the upstream service is unavailable. Keep this policy separate from the pure passcode function and do not couple non-U.S. issuance to FCC availability.

### Custom domain and stronger edge protection

For a branded endpoint, add an API Gateway domain, ACM certificate, and Route 53 record. If abuse warrants AWS WAF, place CloudFront in front of this HTTP API or migrate to a Regional REST API that supports direct WAF association.

