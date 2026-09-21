"""Build a privacy-minimized, callsign-keyed index from the FCC ULS archive."""

from __future__ import annotations

import gzip
import io
import json
import logging
import os
import tempfile
import zipfile
from collections import defaultdict
from datetime import datetime, timezone
from email.utils import parsedate_to_datetime
from typing import Any, Iterator

import boto3


LOGGER = logging.getLogger()
LOGGER.setLevel(logging.INFO)

BUCKET_NAME = os.environ["BUCKET_NAME"]
S3 = boto3.client("s3")


def rows(archive: zipfile.ZipFile, filename: str) -> Iterator[list[str]]:
    with archive.open(filename) as source:
        with io.TextIOWrapper(source, encoding="latin-1", newline="") as text:
            for line in text:
                yield line.rstrip("\r\n").split("|")


def iso_date(value: str) -> str | None:
    if not value:
        return None
    return datetime.strptime(value, "%m/%d/%Y").date().isoformat()


def normalized_name(value: str) -> str:
    value = " ".join(value.split())
    return value.title() if value.isupper() else value


def build_index(archive_path: str) -> dict[str, dict[str, Any]]:
    records_by_id: dict[str, dict[str, Any]] = {}
    with zipfile.ZipFile(archive_path) as archive:
        for fields in rows(archive, "HD.dat"):
            if len(fields) < 10 or fields[5] != "A" or fields[6] not in {"HA", "HV"}:
                continue
            records_by_id[fields[1]] = {
                "callsign": fields[4],
                "status": "Active",
                "radioService": fields[6],
                "grantDate": iso_date(fields[7]),
                "expirationDate": iso_date(fields[8]),
                "fccLicenseId": fields[1],
            }

        for fields in rows(archive, "AM.dat"):
            if len(fields) > 13 and fields[1] in records_by_id and fields[13]:
                records_by_id[fields[1]]["operatorClass"] = fields[13]

        for fields in rows(archive, "EN.dat"):
            if (
                len(fields) > 7
                and fields[1] in records_by_id
                and fields[5] == "L"
                and fields[7]
            ):
                records_by_id[fields[1]]["licenseeName"] = normalized_name(fields[7])

    # Active records are unique by callsign. Keying here also avoids retaining addresses
    # or any other fields from the FCC entity records.
    return {record["callsign"]: record for record in records_by_id.values()}


def dataset_timestamp(source_timestamp: str | None) -> tuple[str, str]:
    if source_timestamp:
        try:
            source_time = datetime.fromisoformat(source_timestamp.replace("Z", "+00:00"))
        except ValueError:
            source_time = parsedate_to_datetime(source_timestamp)
        source_time = source_time.astimezone(timezone.utc)
    else:
        source_time = datetime.now(timezone.utc)
    return source_time.strftime("%Y%m%dT%H%M%SZ"), source_time.isoformat()


def lambda_handler(event: dict[str, Any], context: Any) -> dict[str, Any]:
    del context
    raw_key = event.get("rawKey")
    if (
        not isinstance(raw_key, str)
        or not raw_key.startswith("imports/")
        or not raw_key.endswith("/l_amat.zip")
        or ".." in raw_key
    ):
        raise ValueError("rawKey must identify an imports/.../l_amat.zip object")

    with tempfile.NamedTemporaryFile(suffix=".zip") as temporary_archive:
        object_details = S3.head_object(Bucket=BUCKET_NAME, Key=raw_key)
        S3.download_file(BUCKET_NAME, raw_key, temporary_archive.name)
        temporary_archive.flush()

        source_timestamp = object_details.get("Metadata", {}).get(
            "source-updated-at"
        )
        if not source_timestamp and object_details.get("LastModified"):
            source_timestamp = object_details["LastModified"].isoformat()
        dataset_id, source_updated_at = dataset_timestamp(source_timestamp)

        records = build_index(temporary_archive.name)

    shards: dict[str, dict[str, dict[str, Any]]] = defaultdict(dict)
    for callsign, record in records.items():
        shards[callsign[:3]][callsign] = record

    for shard_name, shard_records in shards.items():
        body = gzip.compress(
            json.dumps(shard_records, separators=(",", ":"), sort_keys=True).encode()
        )
        S3.put_object(
            Bucket=BUCKET_NAME,
            Key=f"datasets/{dataset_id}/shards/{shard_name}.json.gz",
            Body=body,
            ContentType="application/json",
            ContentEncoding="gzip",
        )

    manifest = {
        "datasetId": dataset_id,
        "sourceUpdatedAt": source_updated_at,
        "importedAt": datetime.now(timezone.utc).isoformat(),
        "recordCount": len(records),
        "shardPrefixLength": 3,
        "shards": sorted(shards),
        "source": "FCC ULS Amateur License Public Access File",
    }
    # Publishing the manifest last makes the new dataset visible atomically. A failed
    # import leaves the previous successful manifest and shards in service.
    S3.put_object(
        Bucket=BUCKET_NAME,
        Key="current/manifest.json",
        Body=json.dumps(manifest, separators=(",", ":")).encode(),
        ContentType="application/json",
        CacheControl="no-cache",
    )
    LOGGER.info(json.dumps({"event": "fcc_import_completed", **manifest}))
    return manifest
