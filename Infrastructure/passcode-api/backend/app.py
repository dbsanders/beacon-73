"""Beacon 73 APRS-IS passcode API Lambda handler."""

from __future__ import annotations

import base64
import hashlib
import hmac
import json
import logging
import os
import re
import time
import uuid
from typing import Any

import boto3
from botocore.exceptions import ClientError


LOGGER = logging.getLogger()
LOGGER.setLevel(logging.INFO)

TABLE_NAME = os.environ.get("TABLE_NAME", "beacon73-test")
RATE_LIMIT_REQUESTS = int(os.environ.get("RATE_LIMIT_REQUESTS", "5"))
RATE_LIMIT_WINDOW_SECONDS = int(os.environ.get("RATE_LIMIT_WINDOW_SECONDS", "3600"))
ATTESTATION_RETENTION_DAYS = int(os.environ.get("ATTESTATION_RETENTION_DAYS", "90"))
ATTESTATION_VERSION = os.environ.get("ATTESTATION_VERSION", "v1")
HASH_SALT = os.environ.get("HASH_SALT", "local-test-only")

TABLE = boto3.resource("dynamodb").Table(TABLE_NAME)

# Conservative APRS-IS-compatible international amateur callsign syntax.
# SSIDs are normalized separately before this expression is applied.
CALLSIGN_RE = re.compile(
    r"^(?:[1-9][A-Z][A-Z]?[0-9]|[A-Z][2-9A-Z]?[0-9])[A-Z]{1,4}$",
    re.ASCII,
)
SSID_RE = re.compile(r"^(?P<base>.+)-(?P<ssid>[0-9]{1,2})$", re.ASCII)
MAX_BODY_BYTES = 4096


class ApiError(Exception):
    def __init__(self, status: int, code: str, message: str) -> None:
        super().__init__(message)
        self.status = status
        self.code = code
        self.message = message


def normalize_callsign(raw_callsign: Any) -> str:
    if not isinstance(raw_callsign, str):
        raise ApiError(400, "invalid_callsign", "callsign must be a string")

    callsign = raw_callsign.strip().upper()
    ssid_match = SSID_RE.fullmatch(callsign)
    if ssid_match:
        ssid = int(ssid_match.group("ssid"))
        if not 0 <= ssid <= 15:
            raise ApiError(400, "invalid_callsign", "SSID must be between 0 and 15")
        callsign = ssid_match.group("base")

    if not CALLSIGN_RE.fullmatch(callsign):
        raise ApiError(400, "invalid_callsign", "callsign format is not accepted")
    return callsign


def aprs_is_passcode(callsign: str) -> int:
    """Compute the legacy APRS-IS validation number for a normalized callsign."""
    value = 0x73E2
    encoded = callsign.upper().encode("ascii")
    for index in range(0, len(encoded), 2):
        value ^= encoded[index] << 8
        if index + 1 < len(encoded):
            value ^= encoded[index + 1]
    return value & 0x7FFF


def keyed_hash(value: str) -> str:
    return hmac.new(
        HASH_SALT.encode("utf-8"), value.encode("utf-8"), hashlib.sha256
    ).hexdigest()


def consume_rate_limit(source_ip: str, now: int) -> None:
    window_start = now - (now % RATE_LIMIT_WINDOW_SECONDS)
    rate_key = f"RATE#{keyed_hash(source_ip)}#{window_start}"
    try:
        TABLE.update_item(
            Key={"pk": rate_key},
            UpdateExpression=(
                "SET expires_at = if_not_exists(expires_at, :expires), "
                "record_type = if_not_exists(record_type, :type) "
                "ADD request_count :one"
            ),
            ConditionExpression=(
                "attribute_not_exists(request_count) OR request_count < :limit"
            ),
            ExpressionAttributeValues={
                ":expires": window_start + RATE_LIMIT_WINDOW_SECONDS + 86400,
                ":type": "rate_limit",
                ":one": 1,
                ":limit": RATE_LIMIT_REQUESTS,
            },
        )
    except ClientError as error:
        if error.response.get("Error", {}).get("Code") == "ConditionalCheckFailedException":
            raise ApiError(
                429,
                "rate_limited",
                "too many requests; try again after the current rate-limit window",
            ) from error
        raise


def record_attestation(
    callsign: str, source_ip: str, user_agent: str, request_id: str, now: int
) -> None:
    TABLE.put_item(
        Item={
            "pk": f"ATTESTATION#{request_id}",
            "record_type": "attestation",
            "callsign": callsign,
            "attested": True,
            "attestation_version": ATTESTATION_VERSION,
            "requested_at": now,
            "source_hash": keyed_hash(source_ip),
            "user_agent_hash": keyed_hash(user_agent),
            "expires_at": now + (ATTESTATION_RETENTION_DAYS * 86400),
        },
        ConditionExpression="attribute_not_exists(pk)",
    )


def response(status: int, body: dict[str, Any], request_id: str) -> dict[str, Any]:
    return {
        "statusCode": status,
        "headers": {
            "content-type": "application/json; charset=utf-8",
            "cache-control": "no-store",
            "x-content-type-options": "nosniff",
            "x-request-id": request_id,
        },
        "body": json.dumps(body, separators=(",", ":")),
    }


def parse_body(event: dict[str, Any]) -> dict[str, Any]:
    raw_body = event.get("body")
    if not isinstance(raw_body, str):
        raise ApiError(400, "invalid_request", "a JSON request body is required")
    if event.get("isBase64Encoded"):
        try:
            body_bytes = base64.b64decode(raw_body, validate=True)
        except (ValueError, TypeError) as error:
            raise ApiError(400, "invalid_request", "request body is not valid base64") from error
    else:
        body_bytes = raw_body.encode("utf-8")
    if len(body_bytes) > MAX_BODY_BYTES:
        raise ApiError(413, "request_too_large", "request body is too large")
    try:
        payload = json.loads(body_bytes)
    except (json.JSONDecodeError, UnicodeDecodeError) as error:
        raise ApiError(400, "invalid_json", "request body must be valid JSON") from error
    if not isinstance(payload, dict):
        raise ApiError(400, "invalid_request", "request body must be a JSON object")
    return payload


def lambda_handler(event: dict[str, Any], context: Any) -> dict[str, Any]:
    request_id = getattr(context, "aws_request_id", None) or str(uuid.uuid4())
    now = int(time.time())
    request_context = event.get("requestContext", {})
    http_context = request_context.get("http", {})
    source_ip = str(http_context.get("sourceIp", "unknown"))
    headers = event.get("headers") or {}
    user_agent = str(headers.get("user-agent", "unknown"))[:512]

    try:
        payload = parse_body(event)
        if payload.get("attestation") is not True:
            raise ApiError(
                400,
                "attestation_required",
                "attestation must be explicitly accepted",
            )
        callsign = normalize_callsign(payload.get("callsign"))
        consume_rate_limit(source_ip, now)
        record_attestation(callsign, source_ip, user_agent, request_id, now)
        passcode = aprs_is_passcode(callsign)
        LOGGER.info(
            json.dumps(
                {
                    "event": "passcode_issued",
                    "request_id": request_id,
                    "callsign_hash": keyed_hash(callsign),
                }
            )
        )
        return response(
            200,
            {"callsign": callsign, "passcode": passcode, "attestationRecorded": True},
            request_id,
        )
    except ApiError as error:
        LOGGER.info(
            json.dumps(
                {
                    "event": "request_rejected",
                    "request_id": request_id,
                    "reason": error.code,
                }
            )
        )
        result = response(
            error.status,
            {"error": {"code": error.code, "message": error.message}},
            request_id,
        )
        if error.status == 429:
            result["headers"]["retry-after"] = str(RATE_LIMIT_WINDOW_SECONDS)
        return result
    except Exception:
        LOGGER.exception(
            json.dumps({"event": "request_failed", "request_id": request_id})
        )
        return response(
            500,
            {"error": {"code": "internal_error", "message": "request failed"}},
            request_id,
        )

