# SPDX-License-Identifier: Apache-2.0

from contextlib import contextmanager
from datetime import datetime, timezone
import fcntl
import hashlib
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import uuid

from .errors import ImageError
from .fingerprint import digest_json, sha256_file
from .profile import ImageProfile
from .toolchain import qemu_img_binary


def verify_bundle(
    workspace: Path,
    profile: ImageProfile,
    directory: Path,
    expected_key: str | None = None,
    *,
    use_stamp: bool = False,
    write_stamp: bool = True,
) -> dict:
    if directory.is_symlink() or not directory.is_dir():
        raise ImageError(
            f"image bundle must be a regular directory: {directory}"
        )
    manifest_path = directory / "manifest.json"
    manifest = read_json(manifest_path)
    if (
        manifest.get("schema") != 1
        or manifest.get("profile") != profile.identifier
    ):
        raise ImageError(f"invalid image manifest: {manifest_path}")
    inputs = manifest.get("inputs")
    input_key = manifest.get("input_key")
    if not isinstance(inputs, dict) or digest_json(inputs) != input_key:
        raise ImageError("image manifest input fingerprint is invalid")
    if expected_key is not None and input_key != expected_key:
        raise ImageError("image bundle was built from different inputs")
    if manifest.get("disk_format") != profile.disk_format:
        raise ImageError(
            "image manifest disk format does not match its profile"
        )
    files = manifest.get("files")
    expected_files = {"disk", *(output.name for output in profile.outputs)}
    if not isinstance(files, dict) or set(files) != expected_files:
        raise ImageError("image manifest does not describe its disk")
    for name in sorted(files, key=lambda item: (item == "disk", item)):
        record = files[name]
        if not isinstance(name, str) or not isinstance(record, dict):
            raise ImageError("invalid file entry in image manifest")
        if Path(name).name != name or name in {".", ".."}:
            raise ImageError(f"invalid image artifact name {name!r}")
        path = directory / name
        if not path.is_file() or path.is_symlink():
            raise ImageError(f"missing image artifact: {path}")
        if not isinstance(record.get("sha256"), str):
            raise ImageError(f"invalid image checksum entry: {name}")
        if type(record.get("size")) is not int:
            raise ImageError(f"invalid image size entry: {name}")
        if record["size"] != path.stat().st_size:
            raise ImageError(f"image artifact size mismatch: {name}")
    if use_stamp and _stamp_matches(workspace, directory, manifest):
        return manifest
    for name, record in files.items():
        path = directory / name
        if sha256_file(path) != record.get("sha256"):
            raise ImageError(f"image artifact checksum mismatch: {name}")
    qemu_img = qemu_img_binary(workspace)
    if qemu_img is None:
        raise ImageError("qemu-img is required to verify an image bundle")
    disk_format = manifest.get("disk_format")
    disk = directory / "disk"
    disk_info = json.loads(subprocess.check_output([
        str(qemu_img), "info", "--output=json", "-f", disk_format, str(disk),
    ], text=True))
    if disk_info.get("backing-filename") or disk_info.get("encrypted"):
        raise ImageError("image disk must be standalone and unencrypted")
    if disk_format == "qcow2":
        subprocess.run(
            [str(qemu_img), "check", "-q", "-f", "qcow2", str(disk)],
            check=True,
        )
    if profile.kernel_artifact:
        kernel = directory / profile.kernel_artifact
        readelf = shutil.which("readelf")
        if readelf is None:
            raise ImageError("readelf is required to verify the profile kernel")
        subprocess.run(
            [readelf, "--file-header", str(kernel)],
            check=True,
            stdout=subprocess.DEVNULL,
        )
    if write_stamp:
        mark_verified_bundle(workspace, profile, directory, manifest)
    return manifest


def mark_verified_bundle(
    workspace: Path,
    profile: ImageProfile,
    directory: Path,
    manifest: dict,
) -> None:
    path = directory.resolve()
    states = {
        name: _file_state(directory / name)
        for name in ["manifest.json", *manifest["files"]]
    }
    record = {
        "schema": 1,
        "profile": profile.identifier,
        "bundle_path": str(path),
        "input_key": manifest["input_key"],
        "manifest_sha256": sha256_file(directory / "manifest.json"),
        "files": states,
    }
    marker = _verification_marker(workspace, path)
    marker.parent.mkdir(parents=True, exist_ok=True)
    pending = marker.with_name(marker.name + "." + uuid.uuid4().hex)
    pending.write_text(
        json.dumps(record, sort_keys=True) + "\n", encoding="utf-8"
    )
    os.replace(pending, marker)


def _stamp_matches(workspace: Path, directory: Path, manifest: dict) -> bool:
    path = directory.resolve()
    try:
        marker = read_json(_verification_marker(workspace, path))
        if (
            marker.get("schema") != 1
            or marker.get("profile") != manifest.get("profile")
            or marker.get("bundle_path") != str(path)
            or marker.get("input_key") != manifest.get("input_key")
            or marker.get("manifest_sha256")
            != sha256_file(directory / "manifest.json")
        ):
            return False
        files = marker.get("files")
        if not isinstance(files, dict):
            return False
        expected_names = ["manifest.json", *manifest["files"]]
        return all(
            files.get(name) == _file_state(directory / name)
            for name in expected_names
        )
    except (OSError, ValueError, ImageError):
        return False


def _verification_marker(workspace: Path, directory: Path) -> Path:
    digest = hashlib.sha256(str(directory).encode()).hexdigest()
    return workspace / "build/cache/image-verification" / f"{digest}.json"


def _file_state(path: Path) -> dict:
    state = path.lstat()
    if not stat.S_ISREG(state.st_mode):
        raise ImageError(f"image artifact is not a regular file: {path}")
    return {
        "device": state.st_dev,
        "inode": state.st_ino,
        "mtime_ns": state.st_mtime_ns,
        "ctime_ns": state.st_ctime_ns,
        "size": state.st_size,
    }


def write_manifest(
    profile: ImageProfile,
    fingerprint: dict,
    products: Path,
) -> dict:
    names = {"disk", *(output.name for output in profile.outputs)}
    files = {
        name: {
            "sha256": sha256_file(products / name),
            "size": (products / name).stat().st_size,
        }
        for name in sorted(names)
    }
    manifest = {
        "schema": 1,
        "profile": profile.identifier,
        "input_key": fingerprint["input_key"],
        "inputs": fingerprint["inputs"],
        "disk_format": profile.disk_format,
        "kernel_release": profile.variables.get("kernel_release"),
        "files": files,
        "built_at": datetime.now(timezone.utc).isoformat(),
    }
    (products / "manifest.json").write_text(
        json.dumps(manifest, indent=2) + "\n", encoding="utf-8"
    )
    return manifest


def packer_disk_output(directory: Path, image_name: str) -> Path:
    candidates = [
        directory / image_name,
        directory / f"{image_name}.qcow2",
        directory / f"{image_name}.raw",
    ]
    for candidate in candidates:
        if candidate.is_file():
            return candidate
    remaining = [
        path for path in directory.iterdir()
        if path.is_file() and not path.name.endswith(".json")
    ]
    if len(remaining) == 1:
        return remaining[0]
    raise ImageError(f"Packer did not produce one disk image in {directory}")


@contextmanager
def exclusive_lock(path: Path):
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a+") as lock:
        fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
        try:
            yield
        finally:
            fcntl.flock(lock.fileno(), fcntl.LOCK_UN)


def publish(products: Path, output: Path) -> None:
    previous = None
    if output.exists() or output.is_symlink():
        if output.is_symlink() or not (output / "manifest.json").is_file():
            raise ImageError(
                f"preserving existing unowned image output: {output}"
            )
        previous = output.with_name(f".{output.name}.stale-{uuid.uuid4().hex}")
        os.replace(output, previous)
    try:
        os.replace(products, output)
    except BaseException:
        if previous is not None and previous.exists() and not output.exists():
            os.replace(previous, output)
        raise
    if previous is not None:
        print(f"Preserved previous image bundle at {previous}")


def profile_lock_key(identifier: str) -> str:
    return hashlib.sha256(identifier.encode()).hexdigest()[:24]


def read_json(path: Path) -> dict:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise ImageError(
            f"cannot read image metadata {path}: {error}"
        ) from error
    if not isinstance(value, dict):
        raise ImageError(f"image metadata must be an object: {path}")
    return value
