# SPDX-License-Identifier: Apache-2.0

import argparse
from dataclasses import asdict, replace
import json
from pathlib import Path
import uuid

from scripts.ci.ci_lifecycle import Lifecycle
from scripts.ci.image_artifact import (
    ArtifactMissing, Scope, discard_download, find_image, github,
    record_selection, require_key,
)
from scripts.ci.image_artifact import input_key


def check(key: str, output: Path) -> None:
    scope = Scope.environment()
    with Lifecycle().installed() as lifecycle:
        image = find_image(key, scope, lifecycle)
        if image is None:
            raise AssertionError("no real matching image artifact was found")
        require_key(image.manifest, key)
        token = uuid.uuid4().hex
        changed = {**image.manifest["inputs"], "epoch": token}
        try:
            require_key(image.manifest, input_key(changed))
        except ValueError:
            pass
        else:
            raise AssertionError("consumer accepted different image inputs")
        if find_image(input_key(changed), scope, lifecycle) is not None:
            raise AssertionError("different inputs reused an image artifact")
        for other in (
            replace(scope, branch="image-check-" + token),
            replace(scope, head_repository=-1),
        ):
            if find_image(key, other, lifecycle) is not None:
                raise AssertionError("another source scope reused the image")
        try:
            github([
                f"repos/{scope.repository}/actions/artifacts/0/zip",
            ], lifecycle)
        except ArtifactMissing:
            pass
        else:
            raise AssertionError("a missing artifact was not classified")
        lifecycle.check()
    output.mkdir(parents=True, exist_ok=False)
    record = output / "selection.json"
    directory = record_selection(image, record)
    assert directory is not None
    encoded = json.dumps(image.manifest, indent=2) + "\n"
    (directory / "manifest.json").write_text(encoded)
    preserved = output / "manifest.json"
    preserved.write_text(encoded)
    invalid = {
        **json.loads(record.read_text()), "download_directory": str(output),
    }
    record.write_text(json.dumps(invalid))
    try:
        discard_download(record)
    except ValueError:
        pass
    else:
        raise AssertionError("cleanup accepted the parent artifact directory")
    invalid["download_directory"] = str(directory)
    record.write_text(json.dumps(invalid))
    discard_download(record)
    if directory.exists() or preserved.read_text() != encoded:
        raise AssertionError("partial-download cleanup changed other artifacts")
    result = {"status": "PASS", "scope": asdict(scope), **asdict(image)}
    (output / "verdict.json").write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps({"status": "PASS", "artifact_id": image.artifact_id}))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(
        description="Check image lookup against real GitHub artifacts"
    )
    parser.add_argument("input_key")
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    check(args.input_key, args.output.resolve())
