# SPDX-License-Identifier: Apache-2.0

from pathlib import Path
import shutil
import tempfile
import unittest

from resources.images.profile import ProfileError, list_profiles, load_profile


WORKSPACE = Path(__file__).resolve().parents[2]
PROFILE = "guest/ubuntu/24.04/x86_64/rocm7_0"


class ImageProfileTests(unittest.TestCase):
    def test_rocm_profile_is_discoverable_and_has_a_pinned_base_image(self):
        self.assertIn(PROFILE, list_profiles(WORKSPACE))
        profile = load_profile(WORKSPACE, PROFILE)
        self.assertEqual(profile.distribution, "ubuntu")
        self.assertEqual(profile.release, "24.04")
        self.assertEqual(profile.architecture, "x86_64")
        self.assertEqual(len(profile.base_sha256), 64)
        self.assertEqual(profile.kernel_artifact, "kernel")

    def test_profile_outputs_and_sources_stay_in_the_workspace(self):
        profile = load_profile(WORKSPACE, PROFILE)
        self.assertTrue(
            profile.output_path(WORKSPACE).is_relative_to(WORKSPACE)
        )
        self.assertTrue(profile.tasks_file.is_relative_to(WORKSPACE))
        for path in profile.inputs.values():
            self.assertTrue(path.is_relative_to(WORKSPACE))

    def test_profile_identifier_rejects_parent_traversal(self):
        with self.assertRaises(ProfileError):
            load_profile(WORKSPACE, "../../outside")

    def test_payload_disk_format_must_match_the_builder_output_format(self):
        profile = load_profile(WORKSPACE, PROFILE)
        with tempfile.TemporaryDirectory() as name:
            workspace = Path(name)
            profile_directory = (
                workspace / "resources/images/profiles" / PROFILE
            )
            profile_directory.parent.mkdir(parents=True)
            shutil.copytree(profile.directory, profile_directory)
            profile_file = profile_directory / "profile.toml"
            content = profile_file.read_text(encoding="utf-8")
            current = '[payload]\ndisk_id = "root"\ndisk_format = "qcow2"'
            mismatch = '[payload]\ndisk_id = "root"\ndisk_format = "raw"'
            self.assertIn(current, content)
            profile_file.write_text(
                content.replace(current, mismatch, 1), encoding="utf-8"
            )

            with self.assertRaisesRegex(
                ProfileError,
                "payload.disk_format must match builder.disk_format",
            ):
                load_profile(workspace, PROFILE)

    def test_bundle_metadata_names_cannot_be_provisioning_outputs(self):
        profile = load_profile(WORKSPACE, PROFILE)
        reserved_names = ("disk", "manifest.json", "packer.log", "build.log")
        for reserved_name in reserved_names:
            with self.subTest(output_name=reserved_name):
                with tempfile.TemporaryDirectory() as name:
                    workspace = Path(name)
                    profile_directory = (
                        workspace / "resources/images/profiles" / PROFILE
                    )
                    profile_directory.parent.mkdir(parents=True)
                    shutil.copytree(profile.directory, profile_directory)
                    profile_file = profile_directory / "profile.toml"
                    content = profile_file.read_text(encoding="utf-8")
                    content = content.replace(
                        'name = "kernel"',
                        f'name = "{reserved_name}"',
                        1,
                    )
                    profile_file.write_text(content, encoding="utf-8")

                    with self.assertRaisesRegex(ProfileError, "is reserved"):
                        load_profile(workspace, PROFILE)


if __name__ == "__main__":
    unittest.main()
