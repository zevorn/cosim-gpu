# SPDX-License-Identifier: Apache-2.0

import os
from pathlib import Path
import sys

from .errors import ImageError
from .fingerprint import digest_json, sha256_file
from .profile import ImageProfile
from .toolchain import (
    ANSIBLE_REQUIREMENTS,
    ANSIBLE_ROOT,
    PACKER_ROOT,
    ANSIBLE_CORE_VERSION,
    PACKER_VERSION,
    Toolchain,
)


def input_fingerprint(
    workspace: Path,
    profile: ImageProfile,
    tools: Toolchain,
) -> dict:
    files = input_files(workspace, profile)
    file_hashes = {
        path.relative_to(workspace).as_posix(): sha256_file(path)
        for path in files
    }
    inputs = {
        "schema": 1,
        "profile": profile.identifier,
        "base": {
            "url": profile.base_url,
            "sha256": profile.base_sha256,
            "format": profile.base_format,
        },
        "files": file_hashes,
        "toolchain": {
            "packer": PACKER_VERSION,
            "ansible_core": ANSIBLE_CORE_VERSION,
            "qemu": tools.qemu_version,
            "qemu_architecture": tools.qemu_architecture,
            "qemu_sha256": tools.qemu_sha256,
            "qemu_img": tools.qemu_img_version,
            "qemu_img_sha256": tools.qemu_img_sha256,
            "python": sys.version.split()[0],
        },
        "epoch": os.environ.get("COSIM_ROCM_IMAGE_EPOCH", "1"),
    }
    return {"inputs": inputs, "input_key": digest_json(inputs)}


def input_files(workspace: Path, profile: ImageProfile) -> list[Path]:
    files = [path for _, path in _input_candidates(workspace, profile)]
    for path in files:
        resolved = path.resolve()
        if not resolved.is_relative_to(workspace):
            raise ImageError(f"image input escapes workspace: {path}")
        if not resolved.is_file():
            raise ImageError(f"missing image input: {path}")
    return sorted(set(path.resolve() for path in files))


def reusable_input_issues(
    workspace: Path,
    profile: ImageProfile,
    stored: object,
) -> list[str]:
    if not isinstance(stored, dict):
        return ["image manifest has no input record"]
    issues = []
    if stored.get("schema") != 1 or stored.get("profile") != profile.identifier:
        issues.append("profile identity changed")
    expected_base = {
        "url": profile.base_url,
        "sha256": profile.base_sha256,
        "format": profile.base_format,
    }
    if stored.get("base") != expected_base:
        issues.append("base image identity changed")
    if stored.get("epoch") != os.environ.get("COSIM_ROCM_IMAGE_EPOCH", "1"):
        issues.append("image build epoch changed")
    toolchain = stored.get("toolchain")
    if (
        not isinstance(toolchain, dict)
        or toolchain.get("packer") != PACKER_VERSION
        or toolchain.get("ansible_core") != ANSIBLE_CORE_VERSION
    ):
        issues.append("pinned image provisioning tool versions changed")
    stored_files = stored.get("files")
    if not isinstance(stored_files, dict):
        return issues + ["image manifest has no input file hashes"]
    current_files = set()
    for name, path in _input_candidates(workspace, profile):
        resolved = path.resolve()
        if not resolved.is_relative_to(workspace):
            issues.append(f"image input escapes workspace ({name}): {path}")
            continue
        relative = resolved.relative_to(workspace).as_posix()
        current_files.add(relative)
        if not resolved.is_file():
            if name in profile.reuse_optional_inputs:
                continue
            issues.append(f"missing image input ({name}): {path}")
            continue
        expected_hash = stored_files.get(relative)
        if expected_hash != sha256_file(resolved):
            issues.append(f"image input changed: {relative}")
    for removed in sorted(set(stored_files) - current_files):
        issues.append(f"image input removed: {removed}")
    return issues


def _input_candidates(
    workspace: Path,
    profile: ImageProfile,
) -> list[tuple[str, Path]]:
    shared_directories = [
        workspace / PACKER_ROOT,
        workspace / ANSIBLE_ROOT,
    ]
    candidates = [
        (path.relative_to(workspace).as_posix(), path)
        for directory in shared_directories
        for path in directory.rglob("*")
        if path.is_file()
    ]
    candidates.extend([
        ("resources/images/requirements.txt", workspace / ANSIBLE_REQUIREMENTS),
        (
            "resources/images/builder.py",
            workspace / "resources/images/builder.py",
        ),
        (
            "resources/images/profile.py",
            workspace / "resources/images/profile.py",
        ),
        (
            "resources/images/process.py",
            workspace / "resources/images/process.py",
        ),
        (
            "resources/images/toolchain.py",
            workspace / "resources/images/toolchain.py",
        ),
        (
            "resources/images/bundle.py",
            workspace / "resources/images/bundle.py",
        ),
        (
            "resources/images/errors.py",
            workspace / "resources/images/errors.py",
        ),
        (
            "resources/images/fingerprint.py",
            workspace / "resources/images/fingerprint.py",
        ),
        (
            "resources/images/identity.py",
            workspace / "resources/images/identity.py",
        ),
        ("resources/images/cli.py", workspace / "resources/images/cli.py"),
        (
            profile.profile_file.relative_to(workspace).as_posix(),
            profile.profile_file,
        ),
        (
            profile.tasks_file.relative_to(workspace).as_posix(),
            profile.tasks_file,
        ),
        *profile.inputs.items(),
    ])
    return candidates


def missing_inputs(workspace: Path, profile: ImageProfile) -> list[str]:
    sources: list[tuple[str, Path]] = [
        ("Packer templates", workspace / PACKER_ROOT),
        ("Ansible profiles", workspace / ANSIBLE_ROOT),
        ("Ansible requirements", workspace / ANSIBLE_REQUIREMENTS),
        ("image builder", workspace / "resources/images/builder.py"),
        ("profile loader", workspace / "resources/images/profile.py"),
        ("process runner", workspace / "resources/images/process.py"),
        ("toolchain manager", workspace / "resources/images/toolchain.py"),
        ("bundle manager", workspace / "resources/images/bundle.py"),
        ("image errors", workspace / "resources/images/errors.py"),
        ("fingerprint helper", workspace / "resources/images/fingerprint.py"),
        ("identity helper", workspace / "resources/images/identity.py"),
        ("image CLI", workspace / "resources/images/cli.py"),
        ("profile tasks", profile.tasks_file),
        ("profile metadata", profile.profile_file),
        *profile.inputs.items(),
    ]
    missing = []
    for label, path in sources:
        if label in {"Packer templates", "Ansible profiles"}:
            if not path.is_dir():
                missing.append(f"{label}: {path}")
            elif not path.resolve().is_relative_to(workspace):
                missing.append(f"input escapes workspace ({label}): {path}")
            continue
        if not path.is_file():
            if label == "m5":
                missing.append(
                    f"x86 m5 utility is missing at {path}; "
                    "build it with just build-m5 x86"
                )
            else:
                missing.append(f"{label}: {path}")
            continue
        if not path.resolve().is_relative_to(workspace):
            missing.append(f"input escapes workspace ({label}): {path}")
    return missing


def missing_recipe_files(workspace: Path, profile: ImageProfile) -> list[str]:
    names = [
        "resources/images/builder.py",
        "resources/images/profile.py",
        "resources/images/process.py",
        "resources/images/toolchain.py",
        "resources/images/bundle.py",
        "resources/images/errors.py",
        "resources/images/fingerprint.py",
        "resources/images/identity.py",
        "resources/images/cli.py",
    ]
    paths = [
        workspace / PACKER_ROOT / "qemu.pkr.hcl",
        workspace / ANSIBLE_ROOT / "provision.yml",
        workspace / ANSIBLE_REQUIREMENTS,
        profile.profile_file,
        profile.tasks_file,
        *(workspace / name for name in names),
    ]
    return [str(path) for path in paths if not path.is_file()]
