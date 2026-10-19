"""Send the weekly Beacon 73 passcode callsign report."""

from __future__ import annotations

import gzip
import hashlib
import hmac
import json
import os
from datetime import datetime, time, timedelta, timezone
from typing import Any
from zoneinfo import ZoneInfo

import boto3


TABLE_NAME = os.environ.get("TABLE_NAME", "beacon73-test")
REPORT_TOPIC_ARN = os.environ.get(
    "REPORT_TOPIC_ARN", "arn:aws:sns:us-west-2:000000000000:beacon73-test"
)
REPORT_TIME_ZONE = os.environ.get("REPORT_TIME_ZONE", "America/Los_Angeles")
HASH_SALT = os.environ.get("HASH_SALT", "local-test-only")
FCC_BUCKET_NAME = os.environ.get("FCC_BUCKET_NAME", "beacon73-fcc-test")

TABLE = boto3.resource("dynamodb").Table(TABLE_NAME)
SNS = boto3.client("sns")
S3 = boto3.client("s3")


def previous_week(now: datetime) -> tuple[datetime, datetime]:
    """Return the previous completed Monday-to-Monday interval."""
    time_zone = ZoneInfo(REPORT_TIME_ZONE)
    local_now = now.astimezone(time_zone)
    current_monday = local_now.date() - timedelta(days=local_now.weekday())
    start_date = current_monday - timedelta(days=7)
    return (
        datetime.combine(start_date, time.min, time_zone),
        datetime.combine(current_monday, time.min, time_zone),
    )


def scan_report_records() -> list[dict[str, Any]]:
    items: list[dict[str, Any]] = []
    request: dict[str, Any] = {
        "ProjectionExpression": (
            "pk, record_type, callsign, requested_at, first_requested_at"
        )
    }
    while True:
        result = TABLE.scan(**request)
        items.extend(result.get("Items", []))
        last_key = result.get("LastEvaluatedKey")
        if not last_key:
            return items
        request["ExclusiveStartKey"] = last_key


def keyed_hash(value: str) -> str:
    return hmac.new(
        HASH_SALT.encode("utf-8"), value.encode("utf-8"), hashlib.sha256
    ).hexdigest()


def unique_callsigns(items: list[dict[str, Any]]) -> dict[str, dict[str, Any]]:
    records: dict[str, dict[str, Any]] = {}
    for item in items:
        if item.get("record_type") == "attestation":
            callsign = item.get("callsign")
            if not isinstance(callsign, str):
                continue
            callsign_hash = keyed_hash(callsign)
            timestamp = item.get("requested_at")
        elif item.get("record_type") == "unique_callsign":
            pk = item.get("pk")
            if not isinstance(pk, str) or not pk.startswith("CALLSIGN#"):
                continue
            callsign = None
            callsign_hash = pk.removeprefix("CALLSIGN#")
            timestamp = item.get("first_requested_at")
        else:
            continue
        if timestamp is None:
            continue
        timestamp = int(timestamp)
        record = records.setdefault(
            callsign_hash,
            {"first_requested_at": timestamp, "callsign": callsign},
        )
        record["first_requested_at"] = min(record["first_requested_at"], timestamp)
        if callsign is not None:
            record["callsign"] = callsign
    return records


def retain_unique_callsigns(records: dict[str, dict[str, Any]]) -> None:
    for callsign_hash, record in records.items():
        TABLE.update_item(
            Key={"pk": f"CALLSIGN#{callsign_hash}"},
            UpdateExpression=(
                "SET record_type = if_not_exists(record_type, :record_type), "
                "first_requested_at = if_not_exists(first_requested_at, :first_seen)"
            ),
            ExpressionAttributeValues={
                ":record_type": "unique_callsign",
                ":first_seen": record["first_requested_at"],
            },
        )


def new_callsigns(
    records: dict[str, dict[str, Any]], start: datetime, end: datetime
) -> list[str]:
    start_timestamp = int(start.timestamp())
    end_timestamp = int(end.timestamp())
    return sorted(
        record["callsign"]
        for record in records.values()
        if start_timestamp <= record["first_requested_at"] < end_timestamp
        and record["callsign"] is not None
    )


def fcc_details(callsigns: list[str]) -> tuple[dict[str, dict[str, Any]], str | None]:
    if not callsigns:
        return {}, None
    manifest_result = S3.get_object(
        Bucket=FCC_BUCKET_NAME,
        Key="current/manifest.json",
    )
    manifest = json.loads(manifest_result["Body"].read())
    shard_names = set(manifest.get("shards", []))
    prefixes = sorted({callsign[:3] for callsign in callsigns})
    records: dict[str, dict[str, Any]] = {}
    for prefix in prefixes:
        if prefix not in shard_names:
            continue
        result = S3.get_object(
            Bucket=FCC_BUCKET_NAME,
            Key=f"datasets/{manifest['datasetId']}/shards/{prefix}.json.gz",
        )
        shard = json.loads(gzip.decompress(result["Body"].read()))
        for callsign in callsigns:
            if callsign in shard:
                records[callsign] = shard[callsign]
    return records, manifest.get("sourceUpdatedAt")


def report_body(
    records: dict[str, dict[str, Any]],
    details: dict[str, dict[str, Any]],
    source_updated_at: str | None,
    start: datetime,
    end: datetime,
) -> str:
    callsigns = new_callsigns(records, start, end)
    end_date = end.date() - timedelta(days=1)
    lines = [
        "Beacon 73 weekly passcode callsign report",
        "",
        f"Reporting period: {start.date().isoformat()} through {end_date.isoformat()} "
        f"({REPORT_TIME_ZONE})",
        f"New unique callsigns: {len(callsigns)}",
    ]
    if source_updated_at:
        lines.append(f"FCC data updated: {source_updated_at[:10]}")
    lines.append("")
    if callsigns:
        for callsign in callsigns:
            record = details.get(callsign)
            if not record:
                lines.append(f"{callsign} — No active FCC record found")
                continue
            name = record.get("licenseeName") or "Name unavailable"
            lines.append(f"{callsign} — {name}")
    else:
        lines.append("None")
    lines.extend(["", f"Running total of unique callsigns: {len(records)}"])
    return "\n".join(lines)


def lambda_handler(event: dict[str, Any], context: Any) -> dict[str, Any]:
    del context
    event_time = event.get("time")
    now = (
        datetime.fromisoformat(event_time.replace("Z", "+00:00"))
        if event_time
        else datetime.now(timezone.utc)
    )
    start, end = previous_week(now)
    records = unique_callsigns(scan_report_records())
    retain_unique_callsigns(records)
    callsigns = new_callsigns(records, start, end)
    details, source_updated_at = fcc_details(callsigns)
    body = report_body(records, details, source_updated_at, start, end)
    SNS.publish(
        TopicArn=REPORT_TOPIC_ARN,
        Subject=f"Beacon 73 callsign report — week ending {(end.date() - timedelta(days=1)).isoformat()}",
        Message=body,
    )
    return {
        "newCallsignCount": sum(
            int(start.timestamp())
            <= record["first_requested_at"]
            < int(end.timestamp())
            for record in records.values()
        ),
        "uniqueCallsignCount": len(records),
    }
