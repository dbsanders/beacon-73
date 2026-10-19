import gzip
import io
import json
import os
import sys
import unittest
from datetime import datetime, timezone
from decimal import Decimal
from unittest.mock import MagicMock, call

os.environ.setdefault("AWS_DEFAULT_REGION", "us-west-2")
os.environ.setdefault("AWS_EC2_METADATA_DISABLED", "true")
sys.path.insert(0, os.path.dirname(__file__))

import weekly_report


class WeeklyReportTests(unittest.TestCase):
    def setUp(self):
        weekly_report.TABLE = MagicMock()
        weekly_report.SNS = MagicMock()
        weekly_report.S3 = MagicMock()
        weekly_report.HASH_SALT = "test-salt"

    def test_previous_week_uses_monday_boundaries_in_report_time_zone(self):
        start, end = weekly_report.previous_week(
            datetime(2026, 10, 19, 16, 0, tzinfo=timezone.utc)
        )

        self.assertEqual(start.isoformat(), "2026-10-12T00:00:00-07:00")
        self.assertEqual(end.isoformat(), "2026-10-19T00:00:00-07:00")

    def test_unique_callsigns_combines_attestations_and_retained_records(self):
        result = weekly_report.unique_callsigns(
            [
                {
                    "record_type": "attestation",
                    "callsign": "K6BAT",
                    "requested_at": Decimal("200"),
                },
                {
                    "record_type": "unique_callsign",
                    "pk": f"CALLSIGN#{weekly_report.keyed_hash('K6BAT')}",
                    "first_requested_at": Decimal("100"),
                },
                {
                    "record_type": "attestation",
                    "callsign": "N6AWQ",
                    "requested_at": Decimal("300"),
                },
                {"record_type": "rate_limit"},
            ]
        )

        self.assertEqual(
            result,
            {
                weekly_report.keyed_hash("K6BAT"): {
                    "first_requested_at": 100,
                    "callsign": "K6BAT",
                },
                weekly_report.keyed_hash("N6AWQ"): {
                    "first_requested_at": 300,
                    "callsign": "N6AWQ",
                },
            },
        )

    def test_scan_report_records_follows_pagination(self):
        weekly_report.TABLE.scan.side_effect = [
            {"Items": [{"pk": "first"}], "LastEvaluatedKey": {"pk": "cursor"}},
            {"Items": [{"pk": "second"}]},
        ]

        self.assertEqual(
            weekly_report.scan_report_records(),
            [{"pk": "first"}, {"pk": "second"}],
        )
        self.assertEqual(weekly_report.TABLE.scan.call_count, 2)
        self.assertEqual(
            weekly_report.TABLE.scan.call_args_list[1].kwargs["ExclusiveStartKey"],
            {"pk": "cursor"},
        )

    def test_lambda_publishes_new_callsigns_and_running_total(self):
        weekly_report.TABLE.scan.return_value = {
            "Items": [
                {
                    "record_type": "attestation",
                    "callsign": "N5FL",
                    "requested_at": Decimal("1792272686"),
                },
                {
                    "record_type": "unique_callsign",
                    "pk": f"CALLSIGN#{weekly_report.keyed_hash('K6BAT')}",
                    "first_requested_at": Decimal("1789964023"),
                },
            ]
        }
        manifest = {
            "datasetId": "20261018T120000Z",
            "sourceUpdatedAt": "2026-10-18T12:00:00+00:00",
            "shards": ["N5F"],
        }
        shard = {
            "N5FL": {
                "callsign": "N5FL",
                "licenseeName": "Example, Alice",
            }
        }
        weekly_report.S3.get_object.side_effect = [
            {"Body": io.BytesIO(json.dumps(manifest).encode())},
            {"Body": io.BytesIO(gzip.compress(json.dumps(shard).encode()))},
        ]

        result = weekly_report.lambda_handler(
            {"time": "2026-10-19T16:00:00Z"}, None
        )

        self.assertEqual(result, {"newCallsignCount": 1, "uniqueCallsignCount": 2})
        self.assertEqual(
            weekly_report.TABLE.update_item.call_args_list,
            [
                call(
                    Key={"pk": f"CALLSIGN#{weekly_report.keyed_hash('N5FL')}"},
                    UpdateExpression=(
                        "SET record_type = if_not_exists(record_type, :record_type), "
                        "first_requested_at = if_not_exists(first_requested_at, :first_seen)"
                    ),
                    ExpressionAttributeValues={
                        ":record_type": "unique_callsign",
                        ":first_seen": 1792272686,
                    },
                ),
                call(
                    Key={"pk": f"CALLSIGN#{weekly_report.keyed_hash('K6BAT')}"},
                    UpdateExpression=(
                        "SET record_type = if_not_exists(record_type, :record_type), "
                        "first_requested_at = if_not_exists(first_requested_at, :first_seen)"
                    ),
                    ExpressionAttributeValues={
                        ":record_type": "unique_callsign",
                        ":first_seen": 1789964023,
                    },
                ),
            ],
        )
        published = weekly_report.SNS.publish.call_args.kwargs
        self.assertIn("N5FL", published["Message"])
        self.assertIn("N5FL — Example, Alice", published["Message"])
        self.assertNotIn("K6BAT\n", published["Message"])
        self.assertIn("Running total of unique callsigns: 2", published["Message"])


if __name__ == "__main__":
    unittest.main()
