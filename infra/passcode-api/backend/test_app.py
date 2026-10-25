import gzip
import io
import json
import os
import sys
import unittest
from types import SimpleNamespace
from unittest.mock import MagicMock

os.environ.setdefault("AWS_DEFAULT_REGION", "us-west-2")
os.environ.setdefault("AWS_EC2_METADATA_DISABLED", "true")
sys.path.insert(0, os.path.dirname(__file__))

import app


class PasscodeTests(unittest.TestCase):
    def setUp(self):
        app.TABLE = MagicMock()
        app.S3 = MagicMock()
        app.FCC_CACHE.clear()
        self.context = SimpleNamespace(aws_request_id="test-request")

    def event(self, payload):
        return {
            "body": json.dumps(payload),
            "requestContext": {"http": {"sourceIp": "192.0.2.1"}},
            "headers": {"user-agent": "Beacon73Tests/1"},
        }

    def lookup_event(self, callsign):
        return {
            "requestContext": {
                "routeKey": "GET /v1/callsigns/{callsign}",
                "http": {"sourceIp": "192.0.2.1"},
            },
            "pathParameters": {"callsign": callsign},
            "headers": {"user-agent": "Beacon73Tests/1"},
        }

    def test_known_aprs_passcode(self):
        self.assertEqual(app.aprs_is_passcode("N0CALL"), 13023)
        self.assertEqual(app.aprs_is_passcode("K6BAT"), 11925)

    def test_normalizes_ssid(self):
        self.assertEqual(app.normalize_callsign("  k6bat-15 "), "K6BAT")

    def test_rejects_out_of_range_ssid(self):
        with self.assertRaises(app.ApiError):
            app.normalize_callsign("K6BAT-16")

    def test_attestation_is_required(self):
        result = app.lambda_handler(
            self.event({"callsign": "K6BAT", "attestation": False}), self.context
        )
        self.assertEqual(result["statusCode"], 400)
        self.assertEqual(
            json.loads(result["body"])["error"]["code"], "attestation_required"
        )
        app.TABLE.update_item.assert_not_called()

    def test_success_does_not_store_passcode(self):
        result = app.lambda_handler(
            self.event({"callsign": "K6BAT-7", "attestation": True}), self.context
        )
        self.assertEqual(result["statusCode"], 200)
        body = json.loads(result["body"])
        self.assertEqual(body["callsign"], "K6BAT")
        self.assertIsInstance(body["passcode"], int)

        stored_item = app.TABLE.put_item.call_args.kwargs["Item"]
        self.assertNotIn("passcode", stored_item)
        self.assertTrue(stored_item["attested"])

    def test_fcc_lookup_returns_matching_record(self):
        manifest = {
            "datasetId": "20260920T133208Z",
            "sourceUpdatedAt": "2026-09-20T13:32:08+00:00",
            "recordCount": 823264,
            "shardPrefixLength": 3,
            "shards": ["K6B"],
        }
        record = {
            "K6BAT": {
                "callsign": "K6BAT",
                "status": "Active",
                "licenseeName": "Sanders, Bret",
                "operatorClass": "E",
                "expirationDate": "2035-05-23",
            }
        }
        app.S3.get_object.side_effect = [
            {"Body": io.BytesIO(json.dumps(manifest).encode())},
            {"Body": io.BytesIO(gzip.compress(json.dumps(record).encode()))},
        ]

        result = app.lambda_handler(self.lookup_event("k6bat-5"), self.context)

        self.assertEqual(result["statusCode"], 200)
        body = json.loads(result["body"])
        self.assertEqual(body["callsign"], "K6BAT")
        self.assertEqual(body["record"]["licenseeName"], "Sanders, Bret")
        self.assertEqual(body["dataset"]["recordCount"], 823264)

    def test_canadian_lookup_falls_through_to_ised_registry(self):
        fcc_manifest = {
            "datasetId": "20261025T060000Z",
            "sourceUpdatedAt": "2026-10-25T06:00:00+00:00",
            "recordCount": 823264,
            "shardPrefixLength": 3,
            "shards": ["K6B"],
        }
        canada_manifest = {
            "datasetId": "20261025T060001Z",
            "sourceUpdatedAt": "2026-10-25T06:00:01+00:00",
            "recordCount": 100000,
            "shardPrefixLength": 3,
            "shards": ["VE7"],
            "datasetPrefix": "datasets/canada",
            "source": "ISED Amateur Radio Operator Certificate Services",
            "countryCode": "CA",
            "registryCode": "ISED",
        }
        record = {
            "VE7ABC": {
                "callsign": "VE7ABC",
                "status": "Assigned",
                "licenseeName": "Jane Doe",
            }
        }
        app.S3.get_object.side_effect = [
            {"Body": io.BytesIO(json.dumps(fcc_manifest).encode())},
            {"Body": io.BytesIO(json.dumps(canada_manifest).encode())},
            {"Body": io.BytesIO(gzip.compress(json.dumps(record).encode()))},
        ]

        result = app.lambda_handler(self.lookup_event("ve7abc"), self.context)

        self.assertEqual(result["statusCode"], 200)
        body = json.loads(result["body"])
        self.assertEqual(body["record"]["licenseeName"], "Jane Doe")
        self.assertEqual(body["dataset"]["registryCode"], "ISED")
        self.assertEqual(body["dataset"]["countryCode"], "CA")



if __name__ == "__main__":
    unittest.main()
