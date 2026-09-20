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
        self.context = SimpleNamespace(aws_request_id="test-request")

    def event(self, payload):
        return {
            "body": json.dumps(payload),
            "requestContext": {"http": {"sourceIp": "192.0.2.1"}},
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


if __name__ == "__main__":
    unittest.main()
