# SPDX-License-Identifier: Apache-2.0

import argparse
import errno
import gzip
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess


ROOT = Path(__file__).resolve().parents[2]
IMAGE_ARCHIVE = "development-image.tar.gz"
ARCHIVES = ("gem5.opt.gz", "libvfio-user.a.gz", IMAGE_ARCHIVE)


def build_files(binary: Path) -> dict[str, Path]:
    return {
        "gem5.opt.gz": binary,
        "libvfio-user.a.gz": binary.parent / "ext/libvfio-user/libvfio-user.a",
    }


def sha256(path: Path) -> str:
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def source_identity() -> dict[str, str]:
    identity = {}
    for name, path in (("project", ROOT), ("gem5", ROOT / "third_party/gem5")):
        identity[name] = subprocess.check_output(
            ["git", "-C", str(path), "rev-parse", "HEAD"], text=True
        ).strip()
        subprocess.run(
            ["git", "-C", str(path), "diff", "--quiet", "HEAD", "--"],
            check=True,
        )
    expected = subprocess.check_output(
        ["git", "-C", str(ROOT), "rev-parse", "HEAD:third_party/gem5"],
        text=True,
    ).strip()
    if identity["gem5"] != expected:
        raise ValueError("gem5 checkout differs from the project's gitlink")
    return identity


def image_id(image: str) -> str:
    return subprocess.check_output(
        ["docker", "image", "inspect", "--format", "{{.Id}}", image], text=True
    ).strip()


def build_key() -> str:
    import yaml

    identity = source_identity()
    recipes = json.loads(subprocess.check_output([
        "just", "--justfile", str(ROOT / "justfile"),
        "--dump", "--dump-format", "json",
    ]))
    workflow = yaml.safe_load(
        (ROOT / ".github/workflows/build.yml").read_text()
    )
    inputs = {
        "gem5": identity["gem5"], "architecture": platform.machine(),
        "job": workflow["jobs"]["build-gem5"],
        "workflow_env": workflow.get("env", {}),
        "workflow_defaults": workflow.get("defaults", {}),
        "recipes": {name: recipes["recipes"][name]
                    for name in ("build-gem5", "dev-image")},
        "assignments": recipes["assignments"], "settings": recipes["settings"],
        "files": {name: sha256(ROOT / name) for name in (
            "scripts/build.sh", "scripts/dev.sh", "scripts/Dockerfile.dev",
            "scripts/ci/runtime_artifact.py", ".gitmodules",
        )},
        "epoch": os.environ.get("COSIM_GEM5_CACHE_EPOCH", "1"),
        "environment": {name: os.environ.get(name) for name in (
            "GEM5_BUILD_DIR", "COSIM_HOST_ARCH", "COSIM_DEV_PLATFORM",
            "COSIM_ENV", "COSIM_DEV_IMAGE", "JOBS",
        )},
    }
    return hashlib.sha256(json.dumps(
        inputs, sort_keys=True, separators=(",", ":")
    ).encode()).hexdigest()


def verify_payload(source: Path, manifest: dict) -> None:
    for name in ARCHIVES:
        if sha256(source / name) != manifest["files"][name]:
            raise ValueError(f"artifact checksum mismatch: {name}")


def package(output: Path, binary: Path, image: str) -> None:
    identity = source_identity()
    output.mkdir(parents=True, exist_ok=False)
    payload = build_files(binary)
    for name, path in payload.items():
        with path.open("rb") as source:
            with gzip.open(output / name, "wb", compresslevel=1) as destination:
                shutil.copyfileobj(source, destination)
    with gzip.open(
        output / IMAGE_ARCHIVE, "wb", compresslevel=1
    ) as destination:
        with subprocess.Popen(
            ["docker", "image", "save", image], stdout=subprocess.PIPE
        ) as process:
            assert process.stdout is not None
            shutil.copyfileobj(process.stdout, destination)
            if process.wait() != 0:
                raise RuntimeError("docker image save failed")
    manifest = {
        "version": 2,
        "source": identity,
        "build_source": identity,
        "build_run": os.environ.get("GITHUB_RUN_ID", "local"),
        "build_attempt": os.environ.get("GITHUB_RUN_ATTEMPT", "local"),
        "build_key": build_key(),
        "architecture": platform.machine(),
        "run_id": os.environ.get("GITHUB_RUN_ID", "local"),
        "run_attempt": os.environ.get("GITHUB_RUN_ATTEMPT", "local"),
        "image": image,
        "image_id": image_id(image),
        "files": {
            name: sha256(output / name) for name in (*payload, IMAGE_ARCHIVE)
        },
    }
    (output / "manifest.json").write_text(
        json.dumps(manifest, indent=2) + "\n", encoding="utf-8"
    )


def reuse(source: Path, output: Path, image: str) -> None:
    manifest = json.loads((source / "manifest.json").read_text())
    identity = source_identity()
    expected = {
        "version": 2, "build_key": build_key(), "image": image,
        "architecture": platform.machine(),
    }
    for key, value in expected.items():
        if manifest[key] != value:
            raise ValueError(f"cached build {key} mismatch")
    if manifest["build_source"]["gem5"] != identity["gem5"]:
        raise ValueError("cached binary has a different gem5 source revision")
    verify_payload(source, manifest)
    output.mkdir(parents=True, exist_ok=False)
    for name in ARCHIVES:
        try:
            os.link(source / name, output / name)
        except OSError as error:
            if error.errno != errno.EXDEV:
                raise
            shutil.copy2(source / name, output / name)
    manifest["source"] = identity
    manifest["run_id"] = os.environ.get("GITHUB_RUN_ID", "local")
    manifest["run_attempt"] = os.environ.get("GITHUB_RUN_ATTEMPT", "local")
    (output / "manifest.json").write_text(
        json.dumps(manifest, indent=2) + "\n"
    )


def restore(source: Path, binary: Path, image: str) -> None:
    manifest = json.loads(
        (source / "manifest.json").read_text(encoding="utf-8")
    )
    expected = {
        "version": 2,
        "source": source_identity(),
        "architecture": platform.machine(),
        "run_id": os.environ.get("GITHUB_RUN_ID", "local"),
        "image": image,
    }
    for key, value in expected.items():
        if manifest[key] != value:
            raise ValueError(f"artifact {key} mismatch: {manifest[key]!r}")
    payload = build_files(binary)
    verify_payload(source, manifest)
    subprocess.run(
        ["docker", "image", "load", "--input", str(source / IMAGE_ARCHIVE)],
        check=True,
    )
    if image_id(image) != manifest["image_id"]:
        raise ValueError("loaded development image differs from build image")
    for name, path in payload.items():
        path.parent.mkdir(parents=True, exist_ok=True)
        with gzip.open(source / name, "rb") as compressed:
            with path.open("wb") as destination:
                shutil.copyfileobj(compressed, destination)
    binary.chmod(0o755)


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Transfer a verified gem5 build"
    )
    commands = parser.add_subparsers(dest="operation", required=True)
    commands.add_parser("key")
    for name in ("package", "restore"):
        command = commands.add_parser(name)
        command.add_argument("directory", type=Path)
        command.add_argument("binary", type=Path)
    command = commands.add_parser("reuse")
    command.add_argument("source", type=Path)
    command.add_argument("output", type=Path)
    args = parser.parse_args()
    image = os.environ.get("COSIM_DEV_IMAGE", "cosim-dev:local")
    if args.operation == "key":
        print(build_key())
    elif args.operation == "reuse":
        reuse(args.source, args.output, image)
    else:
        operation = package if args.operation == "package" else restore
        operation(args.directory, args.binary, image)


if __name__ == "__main__":
    main()
