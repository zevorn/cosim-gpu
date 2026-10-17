# SPDX-License-Identifier: Apache-2.0

import argparse
import json
import os
from pathlib import Path
import shutil
import tempfile

from resources.images.builder import build_profile, inspect_profile
from resources.images.bundle import verify_bundle
from resources.images.errors import ImageError
from resources.images.profile import load_profile


PROFILE = "guest/ubuntu/24.04/x86_64/rocm7_0"


def check(output: Path) -> None:
    workspace = Path(__file__).resolve().parents[2]
    profile = load_profile(workspace, PROFILE)
    state = inspect_profile(workspace, PROFILE)
    if state["status"] != "ready":
        build_profile(workspace, PROFILE)
    manifest = json.loads(
        (profile.output_path(workspace) / "manifest.json").read_text()
    )
    if output.resolve() != profile.output_path(workspace).resolve():
        raise ValueError(
            "the requested image directory must be "
            f"{profile.output_path(workspace)}"
        )
    with tempfile.TemporaryDirectory(
        prefix="image-integrity-", dir=output.parent
    ) as name:
        directory = Path(name)
        for product in manifest["files"]:
            destination = directory / product
            if product == "kernel":
                shutil.copy2(output / product, destination)
            else:
                os.link(output / product, destination)
        shutil.copy2(output / "manifest.json", directory / "manifest.json")
        kernel = directory / "kernel"
        with kernel.open("r+b") as stream:
            stream.truncate(kernel.stat().st_size - 1)
        try:
            verify_bundle(workspace, profile, directory, manifest["input_key"])
        except ImageError as error:
            message = str(error)
            if not any(
                reason in message
                for reason in (
                    "size mismatch: kernel",
                    "checksum mismatch: kernel",
                )
            ):
                raise
        else:
            raise AssertionError("a truncated paired kernel was accepted")
    print(json.dumps({"status": "PASS", "input_key": manifest["input_key"]}))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(
        description="Check integrity gates using a real built ROCm image"
    )
    parser.add_argument("output", type=Path)
    check(parser.parse_args().output.resolve())
