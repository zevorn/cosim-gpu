# SPDX-License-Identifier: Apache-2.0

import os
from pathlib import Path
import unittest

from resources.images.fingerprint import sha256_file
from resources.images.identity import _input_candidates, reusable_input_issues
from resources.images.profile import load_profile
from resources.images.toolchain import ANSIBLE_CORE_VERSION, PACKER_VERSION


WORKSPACE = Path(__file__).resolve().parents[2]
PROFILE_ID = "guest/ubuntu/24.04/x86_64/rocm7_0"


class ReusableImageInputTests(unittest.TestCase):
    def test_removed_recipe_file_invalidates_a_previous_bundle(self):
        profile = load_profile(WORKSPACE, PROFILE_ID)
        files = {}
        for _, path in _input_candidates(WORKSPACE, profile):
            resolved = path.resolve()
            if resolved.is_file():
                files[resolved.relative_to(WORKSPACE).as_posix()] = (
                    sha256_file(resolved)
                )
        stored = {
            "schema": 1,
            "profile": profile.identifier,
            "base": {
                "url": profile.base_url,
                "sha256": profile.base_sha256,
                "format": profile.base_format,
            },
            "epoch": os.environ.get("COSIM_ROCM_IMAGE_EPOCH", "1"),
            "toolchain": {
                "packer": PACKER_VERSION,
                "ansible_core": ANSIBLE_CORE_VERSION,
            },
            "files": files,
        }
        baseline_issues = reusable_input_issues(WORKSPACE, profile, stored)

        removed_path = "resources/images/packer/removed-template.pkr.hcl"
        stored["files"][removed_path] = "0" * 64

        issues = reusable_input_issues(WORKSPACE, profile, stored)
        self.assertEqual(
            issues,
            [*baseline_issues, f"image input removed: {removed_path}"],
        )


if __name__ == "__main__":
    unittest.main()
