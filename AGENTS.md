# Beacon project guidance

## Project and layout

Beacon 73 is a SwiftUI APRS-IS client with a Live Activity, a static website, and a Python passcode/FCC lookup service. Read `README.md` and `infra/passcode-api/README.md` for the area being changed.

- App: `Beacon/`; Live Activity: `BeaconLiveActivity/`; tests: `BeaconTests/`.
- Xcode project and scheme: `Beacon.xcodeproj`, `Beacon`.
- Website: `website/`; API and FCC importer: `infra/passcode-api/backend/`.
- FCC import automation: `.github/workflows/fcc-callsign-import.yml`.

## Preserve these behaviors

- Demo mode and fallback map positions must never transmit. Live transmission requires configured identity, real GPS position, and a verified APRS-IS connection.
- Preserve manual/automatic cooldowns and overlapping-send protection. Automatic beaconing must not resume merely because the app restarts.
- Require explicit callsign authorization attestation. FCC lookup is informational and must not silently become a gate that excludes non-U.S. operators.
- Store retained passcodes in Keychain. Keep callsigns, passcodes, request bodies, and raw IP addresses out of diagnostic logs and analytics.
- Publish FCC manifests only after all shards are ready; failures preserve the last good dataset. Keep GitHub OIDC trust scoped to the intended repository and branch.
- For release work, synchronize app and extension version/build settings. Preserve submitted release tags and APRS artwork attribution.

## Checks

- App: Product > Test with the Beacon scheme, or `xcodebuild test -project Beacon.xcodeproj -scheme Beacon -destination 'platform=iOS Simulator,name=<installed simulator>'` from the repository root.
- Use a physical device for background location, haptics, and Live Activity behavior.
- Backend: from `infra/passcode-api`, install `backend/requirements-dev.txt` in a local virtual environment, then run `python -m unittest discover -s backend -p 'test_*.py'`.

## Working agreements

- Suggest useful features when coding and ask when intended direction is unclear.
- Preserve unrelated user changes. Never commit credentials, SSO caches, Terraform state, `.terraform/`, or secret variable files.

## AWS and Terraform

These rules are included here so this repository and its worktrees do not depend on a parent-directory instructions file.

- Production profile: `beacon-prod`; expected account: `422095364378`; primary region: `us-west-2`. Choose credentials from this project, never from the open Console tab or default profile.
- Terraform root: `infra/passcode-api`. Read its backend configuration and deployment documentation before initialization. Use its dedicated remote state; do not invent a backend or silently switch to local state.
- Before Terraform commands that inspect/change remote state or AWS resources, explicitly set `AWS_PROFILE=beacon-prod`, `AWS_REGION=us-west-2`, and `AWS_DEFAULT_REGION=us-west-2`, run `aws sts get-caller-identity`, and compare `Account` with `422095364378`. Stop on mismatch. If SSO expired, run `aws sso login --profile beacon-prod` and repeat the check.
- Keep the profile explicit on AWS/Terraform invocations. Preserve configured provider region overrides, such as `us-east-1` for CloudFront certificates where present.
- Do not use `[default]`, legacy `warnwatcher`, or `grammy-cookbook` profiles. Use sandbox account `029939160999` only when explicitly requested. Shared AWS Organizations/bootstrap work belongs to the separate account-infrastructure project.
- Run `terraform fmt -check`, `terraform validate`, and `terraform plan` in the relevant root before applying, when applicable. Inspect the full plan and call out replacements, deletions, IAM, DNS, and public-access changes.
- Apply only when the task authorizes the change. Do not use `-auto-approve` unless unattended application was explicitly requested. Re-plan after applying; a completed deployment should normally have no pending changes.
- Stop on missing backend configuration or unexpected state. Before moving/importing/deleting/recreating resources, identify their account, Terraform addresses, dependencies, migration needs, and rollback implications. Prefer importing existing resources when appropriate; remove old cross-account copies only after authorized cleanup.
- Use IAM Identity Center/SSO, not long-lived IAM user keys. Console and CLI sessions are independent; routine Console work uses the project account's `TerraformAdministrator` role, not root credentials.
