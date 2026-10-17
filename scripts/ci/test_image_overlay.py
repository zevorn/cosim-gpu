# SPDX-License-Identifier: Apache-2.0

import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

from runtime_artifact import sha256


ROOT = Path(__file__).resolve().parents[2]


class ImageOverlayTests(unittest.TestCase):
    def test_writes_to_overlay_without_changing_the_profile_disk(self):
        qemu_img = shutil.which("qemu-img")
        qemu_io = shutil.which("qemu-io")
        self.assertIsNotNone(qemu_img)
        self.assertIsNotNone(qemu_io)
        scratch = ROOT / "build/tests/image-overlay"
        scratch.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(prefix="case-", dir=scratch) as name:
            directory = Path(name)
            backing = directory / "profile.qcow2"
            overlay = directory / "session.qcow2"
            subprocess.run(
                [qemu_img, "create", "-f", "qcow2", str(backing), "8M"],
                check=True,
                stdout=subprocess.DEVNULL,
            )
            original = sha256(backing)
            subprocess.run(
                [
                    "bash",
                    "-c",
                    'source "$1"; cosim_create_disk_overlay "$2" "$3" "$4"',
                    "bash",
                    str(ROOT / "scripts/cosim_lib.sh"),
                    qemu_img,
                    str(backing),
                    str(overlay),
                ],
                check=True,
                stdout=subprocess.DEVNULL,
            )
            subprocess.run(
                [
                    qemu_io,
                    "-f",
                    "qcow2",
                    "-c",
                    "write -P 0x5a 0 512",
                    str(overlay),
                ],
                check=True,
                stdout=subprocess.DEVNULL,
            )
            info = json.loads(subprocess.check_output([
                qemu_img, "info", "--output=json", "-f", "qcow2", str(overlay)
            ], text=True))
            self.assertEqual(sha256(backing), original)
            self.assertTrue(info.get("backing-filename"))
            subprocess.run(
                [qemu_img, "check", "-q", "-f", "qcow2", str(overlay)],
                check=True,
            )

    def test_raw_backing_disk_is_preserved_by_the_qcow2_overlay(self):
        qemu_img = shutil.which("qemu-img")
        qemu_io = shutil.which("qemu-io")
        self.assertIsNotNone(qemu_img)
        self.assertIsNotNone(qemu_io)
        scratch = ROOT / "build/tests/image-overlay"
        scratch.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(prefix="case-", dir=scratch) as name:
            directory = Path(name)
            backing = directory / "profile.raw"
            overlay = directory / "session.qcow2"
            subprocess.run(
                [qemu_img, "create", "-f", "raw", str(backing), "8M"],
                check=True,
                stdout=subprocess.DEVNULL,
            )
            original = sha256(backing)
            subprocess.run(
                [
                    "bash",
                    "-c",
                    'source "$1"; cosim_create_disk_overlay "$2" "$3" "$4"',
                    "bash",
                    str(ROOT / "scripts/cosim_lib.sh"),
                    qemu_img,
                    str(backing),
                    str(overlay),
                ],
                check=True,
                stdout=subprocess.DEVNULL,
            )
            subprocess.run(
                [
                    qemu_io,
                    "-f",
                    "qcow2",
                    "-c",
                    "write -P 0x5a 0 512",
                    str(overlay),
                ],
                check=True,
                stdout=subprocess.DEVNULL,
            )
            info = json.loads(subprocess.check_output([
                qemu_img, "info", "--output=json", "-f", "qcow2", str(overlay)
            ], text=True))
            self.assertEqual(sha256(backing), original)
            self.assertEqual(info.get("backing-filename-format"), "raw")
            subprocess.run(
                [qemu_img, "check", "-q", "-f", "qcow2", str(overlay)],
                check=True,
            )


if __name__ == "__main__":
    unittest.main()
