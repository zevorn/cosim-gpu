# SPDX-License-Identifier: Apache-2.0

import os
import json
from pathlib import Path
import tempfile
import unittest

from resources.images.bundle import _stamp_matches, mark_verified_bundle
from resources.images.fingerprint import digest_json, sha256_file
from resources.images.profile import load_profile


WORKSPACE = Path(__file__).resolve().parents[2]
PROFILE_ID = "guest/ubuntu/24.04/x86_64/rocm7_0"


class ImageBundleVerificationStampTests(unittest.TestCase):
    def test_stamp_rejects_replaced_artifact_with_preserved_timestamp(self):
        profile = load_profile(WORKSPACE, PROFILE_ID)
        with tempfile.TemporaryDirectory() as name:
            temporary = Path(name)
            workspace = temporary / "workspace"
            bundle = temporary / "bundle"
            workspace.mkdir()
            bundle.mkdir()
            disk = bundle / "disk"
            disk.write_bytes(b"original image")
            inputs = {"schema": 1, "profile": PROFILE_ID}
            manifest = {
                "schema": 1,
                "profile": PROFILE_ID,
                "input_key": digest_json(inputs),
                "inputs": inputs,
                "disk_format": "qcow2",
                "files": {
                    "disk": {
                        "sha256": sha256_file(disk),
                        "size": disk.stat().st_size,
                    },
                },
            }
            (bundle / "manifest.json").write_text(
                json.dumps(manifest), encoding="utf-8"
            )
            mark_verified_bundle(workspace, profile, bundle, manifest)
            self.assertTrue(_stamp_matches(workspace, bundle, manifest))

            original_state = disk.stat()
            replacement = bundle / "replacement"
            replacement.write_bytes(b"tampered image")
            os.utime(
                replacement,
                ns=(original_state.st_atime_ns, original_state.st_mtime_ns),
            )
            replacement.replace(disk)

            self.assertFalse(_stamp_matches(workspace, bundle, manifest))


if __name__ == "__main__":
    unittest.main()
