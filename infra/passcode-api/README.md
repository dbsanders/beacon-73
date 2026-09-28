# Beacon 73 AWS infrastructure

This Terraform root manages the AWS infrastructure for Beacon 73: the serverless APRS-IS passcode and FCC callsign API, plus the public website at `https://beacon73.com`.

## Architecture

- **API Gateway HTTP API** exposes `POST /v1/passcode` and applies a stage-wide burst/rate ceiling.
- **Lambda (Python 3.12, arm64)** validates requests and calculates the passcode.
- **DynamoDB on-demand** stores short-lived rate counters and attestation audit records in one encrypted table.
- **S3** privately stores the FCC weekly archive and a compact, privacy-minimized callsign index split into gzip-compressed shards.
- **A scheduled GitHub Actions workflow** downloads the official FCC archive, uploads it with short-lived AWS credentials, and invokes a Lambda that rebuilds the index. The new manifest is published only after every shard is ready.
- **CloudWatch Logs** retains structured Lambda and API access logs for 30 days by default. Access logs omit request bodies and source IPs.
- **S3 and CloudFront** publish the static marketing, support, and privacy site from a private, encrypted, versioned bucket.
- **ACM** provides the website certificate in `us-east-1`; Cloudflare hosts the public DNS records.

There are no always-on servers. For a small app, the AWS usage should generally remain within or near serverless free-tier levels, depending on traffic and account eligibility. DynamoDB point-in-time recovery is enabled as a secure default and may add a small charge.

## API contract

The app should display this text next to an unchecked control:

> I attest that I am a licensed amateur-radio operator and am the licensee, trustee, or otherwise authorized to use this callsign.

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

The app can look up a normalized callsign before showing the attestation:

```http
GET /v1/callsigns/K6BAT-7
```

When the current FCC dataset contains the callsign, the response includes the public licensee name, status, operator class, grant and expiration dates, FCC license ID, and dataset update time. It deliberately excludes postal addresses and contact details. A valid callsign that is absent from the FCC data returns `record: null`; this does not prevent attestation, because non-U.S. callsigns are outside the FCC dataset.

## What is recorded

Each accepted request creates an attestation record containing the normalized callsign, attestation version, time, and keyed hashes of the source IP and user agent. The raw source IP, raw user agent, and passcode are not stored. Attestation records expire after 90 days by default. DynamoDB TTL deletion is asynchronous, so AWS may retain an expired record briefly after its expiration timestamp.

Rate-limit entries use only a keyed source-IP hash and fixed-window timestamp. They expire after the window plus a one-day cleanup buffer. The default limits are 5 accepted passcode attempts and 30 callsign lookups per source IP per hour. Invalid requests that fail before callsign validation do not consume these quotas; API Gateway still protects the service-wide request rate.

## Prerequisites

- Terraform 1.6 or newer
- AWS IAM Identity Center profile `beacon-prod`, which targets account `422095364378`
- AWS credentials with permission to create API Gateway, Lambda, DynamoDB, S3, IAM/OIDC role and policy, and CloudWatch resources
- Python 3.12 for local tests

Production state is stored in `terraform-state-422095364378-us-west-2` under `beacon/passcode-api/prod/terraform.tfstate`. The local `backend.hcl` file is ignored; copy `backend.hcl.example` for a fresh checkout. Terraform state contains the generated HMAC salt used to pseudonymize network identifiers and the state for the website resources.

## Deploy

```sh
aws sso login --profile beacon-prod
AWS_PROFILE=beacon-prod terraform init -backend-config=backend.hcl
AWS_PROFILE=beacon-prod terraform plan -out=tfplan
AWS_PROFILE=beacon-prod terraform apply tfplan
AWS_PROFILE=beacon-prod terraform output -raw passcode_endpoint
```

Website files live in `../../website`. After publishing a time-sensitive update, invalidate the CloudFront cache with the managed distribution output:

```sh
AWS_PROFILE=beacon-prod aws cloudfront create-invalidation \
  --distribution-id "$(AWS_PROFILE=beacon-prod terraform output -raw website_cloudfront_distribution_id)" \
  --paths '/*'
```

The GitHub Actions workflow in `.github/workflows/fcc-callsign-import.yml` runs each Sunday at 18:00 UTC and can also be started manually. It uses GitHub OIDC to assume a repository-and-branch-restricted AWS role; no long-lived AWS key or GitHub secret is required.

The role trusts GitHub's immutable subject for this repository on `main`: `repo:dbsanders@21073778/beacon-73@1378536487:ref:refs/heads/main`. To check the repository's current subject settings, run `gh api repos/dbsanders/beacon-73/actions/oidc/customization/sub`. When `use_immutable_subject` is true, a name-only subject will fail with `Not authorized to perform sts:AssumeRoleWithWebIdentity`. Keep the trust condition aligned with GitHub's `sub_claim_prefix` plus `:ref:refs/heads/main`; do not broaden it to other repositories or branches.

For a manual import outside GitHub, first place the official archive under an `imports/.../l_amat.zip` key with `source-updated-at` object metadata, then invoke the processor with that key:

```sh
AWS_PROFILE=beacon-prod aws lambda invoke \
  --region us-west-2 \
  --function-name "$(AWS_PROFILE=beacon-prod terraform output -raw fcc_importer_function_name)" \
  --cli-binary-format raw-in-base64-out \
  --payload '{"rawKey":"imports/20260920T133208Z/l_amat.zip"}' \
  /tmp/beacon73-fcc-import.json
cat /tmp/beacon73-fcc-import.json
```

Test the read-only lookup endpoint without creating an attestation:

```sh
curl --fail-with-body \
  "$(AWS_PROFILE=beacon-prod terraform output -raw callsign_lookup_endpoint_template | sed 's/{callsign}/K6BAT/')"
```

You can override defaults in `terraform.tfvars`:

```hcl
aws_region                 = "us-west-2"
environment                = "prod"
rate_limit_requests        = 5
lookup_rate_limit_requests = 30
rate_limit_window_seconds  = 3600
attestation_retention_days = 90
log_retention_days         = 30
```

Smoke-test the deployed endpoint:

```sh
curl --fail-with-body \
  -H 'content-type: application/json' \
  --data '{"callsign":"K6BAT-7","attestation":true}' \
  "$(AWS_PROFILE=beacon-prod terraform output -raw passcode_endpoint)"
```

Destroy the development stack when no longer needed:

```sh
AWS_PROFILE=beacon-prod terraform destroy
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
- The API Lambda can read only the published manifest and processed FCC shards. The importer can write only to the private FCC bucket and its own logs.
- API responses disable caching. Logs contain request IDs, result codes, and keyed hashes only—not request bodies, raw IP addresses, callsigns, or passcodes.
- The callsign validator is intentionally conservative and based on APRS-IS international syntax guidance. It validates syntax, not license ownership or status.
- A failed download or import leaves the previous manifest in place, so callers continue using the last successfully published dataset. Raw FCC archives expire after 35 days and processed datasets after 180 days.
- The importer error alarm records alarm state in CloudWatch. Add an SNS alarm action later if email or paging notifications are desired; GitHub reports scheduled workflow failures in the repository Actions UI.
- A deterministic APRS-IS passcode is not a strong authentication secret. This endpoint's controls are intended to discourage anonymous bulk generation and record the user's attestation.
- API Gateway throttling is best-effort and account/region quotas also apply. The DynamoDB conditional update enforces the per-source application limit atomically.

## Planned extension points

### Apple App Attest

Add an App Attest assertion and key ID to the request. Verify the assertion before `consume_rate_limit`, with keys/challenge state in a separate DynamoDB table or a dedicated verification service. Once enforced, increase confidence that requests originate from a genuine Beacon 73 installation. Keep a short migration period if old app versions must continue working.

### FCC lookup policy

The FCC result is informational and is not currently a passcode-issuance gate. If the FCC download, importer, or lookup is unavailable, the app still permits the user to make the same explicit authorization attestation. This avoids blocking non-U.S. operators and allows the last good weekly dataset to remain useful during an upstream outage. A future policy can require an active FCC record for identified U.S. callsigns without changing the pure passcode function.

### Custom domain and stronger edge protection

For a branded endpoint, add an API Gateway domain, ACM certificate, and Route 53 record. If abuse warrants AWS WAF, place CloudFront in front of this HTTP API or migrate to a Regional REST API that supports direct WAF association.
