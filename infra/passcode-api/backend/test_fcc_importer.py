import os
import sys
import tempfile
import unittest
import zipfile

os.environ.setdefault("AWS_DEFAULT_REGION", "us-west-2")
os.environ.setdefault("AWS_EC2_METADATA_DISABLED", "true")
os.environ.setdefault("BUCKET_NAME", "beacon73-fcc-test")
sys.path.insert(0, os.path.dirname(__file__))

import fcc_importer


class FccImporterTests(unittest.TestCase):
    def test_build_index_keeps_only_active_license_fields(self):
        files = {
            "HD.dat": (
                "HD|1|||K6BAT|A|HV|02/28/2025|05/23/2035|\n"
                "HD|2|||N0OLD|E|HA|01/01/2000|01/01/2010|\n"
            ),
            "AM.dat": "AM|1|||K6BAT|||||||||E|\n",
            "EN.dat": (
                "EN|1|||K6BAT|L||SANDERS, BRET|Bret||Sanders|||||"
                "12 Private Street|Irvine|CA|92620|\n"
            ),
        }
        with tempfile.NamedTemporaryFile(suffix=".zip") as archive_file:
            with zipfile.ZipFile(archive_file.name, "w") as archive:
                for name, body in files.items():
                    archive.writestr(name, body)

            records = fcc_importer.build_index(archive_file.name)

        self.assertEqual(set(records), {"K6BAT"})
        self.assertEqual(records["K6BAT"]["licenseeName"], "Sanders, Bret")
        self.assertEqual(records["K6BAT"]["operatorClass"], "E")
        self.assertEqual(records["K6BAT"]["expirationDate"], "2035-05-23")
        self.assertNotIn("address", records["K6BAT"])

    def test_dataset_timestamp_accepts_iso_metadata(self):
        dataset_id, source_updated_at = fcc_importer.dataset_timestamp(
            "2026-09-20T13:32:08Z"
        )

        self.assertEqual(dataset_id, "20260920T133208Z")
        self.assertEqual(source_updated_at, "2026-09-20T13:32:08+00:00")


if __name__ == "__main__":
    unittest.main()
