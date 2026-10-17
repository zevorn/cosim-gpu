# SPDX-License-Identifier: Apache-2.0

from pathlib import Path
import subprocess
import unittest


ROOT = Path(__file__).resolve().parents[2]
PATH_HELPERS = ROOT / "scripts/cosim_lib.sh"


def resolve_gem5_build_dir(configured: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [
            "bash", "-c",
            'source "$1"; cosim_gem5_build_dir "$2" "$3"',
            "bash", str(PATH_HELPERS), str(ROOT), configured,
        ],
        capture_output=True, text=True, check=False,
    )


class Gem5BuildPathTests(unittest.TestCase):
    def test_resolves_workspace_relative_directory(self):
        result = resolve_gem5_build_dir("build/gem5/x86_64/VEGA_X86")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "build/gem5/x86_64/VEGA_X86")

    def test_maps_absolute_workspace_directory_to_container_path(self):
        result = resolve_gem5_build_dir(
            str(ROOT / "build/gem5/x86_64/VEGA_X86")
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "build/gem5/x86_64/VEGA_X86")

    def test_rejects_directories_outside_the_build_root(self):
        result = resolve_gem5_build_dir(
            "third_party/gem5/build/x86_64/VEGA_X86"
        )
        self.assertNotEqual(result.returncode, 0)

    def test_rejects_parent_directory_traversal(self):
        result = resolve_gem5_build_dir("build/gem5/../outside")
        self.assertNotEqual(result.returncode, 0)
