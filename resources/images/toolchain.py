# SPDX-License-Identifier: Apache-2.0

from dataclasses import asdict, dataclass
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shutil
import subprocess
import urllib.error
import urllib.request
import zipfile

from .errors import ImageError
from .fingerprint import sha256_file
from .process import run_logged
from .profile import ImageProfile


PACKER_VERSION = "1.16.1"
ANSIBLE_CORE_VERSION = "2.18.6"
IMAGE_TOOL_DIR = Path("build/tools/images")
PACKER_ROOT = Path("resources/images/packer")
ANSIBLE_ROOT = Path("resources/images/ansible")
ANSIBLE_REQUIREMENTS = Path("resources/images/requirements.txt")


@dataclass(frozen=True)
class Toolchain:
    qemu: Path
    qemu_architecture: str
    qemu_img: Path
    qemu_version: str
    qemu_sha256: str
    qemu_img_version: str
    qemu_img_sha256: str


def inspect_toolchain(
    workspace: Path,
    profile: ImageProfile,
    *,
    require_kernel_tools: bool = True,
) -> tuple[Toolchain | None, list[str]]:
    missing: list[str] = []
    qemu = qemu_binary(workspace, profile.architecture)
    qemu_img = qemu_img_binary(workspace)
    if qemu is None:
        missing.append(
            "QEMU executable is missing; build it with just build-qemu "
            "or set COSIM_IMAGE_QEMU_BIN/QEMU_BIN"
        )
    if qemu_img is None:
        missing.append(
            "qemu-img is missing; install qemu-utils or set "
            "COSIM_IMAGE_QEMU_IMG/QEMU_IMG"
        )
    if (
        require_kernel_tools
        and profile.kernel_artifact
        and shutil.which("readelf") is None
        and qemu_img is not None
    ):
        missing.append("readelf is missing; install binutils")
    if missing:
        return None, missing
    assert qemu is not None and qemu_img is not None
    try:
        qemu_version = subprocess.check_output(
            [str(qemu), "--version"], text=True
        ).splitlines()[0]
        qemu_img_version = subprocess.check_output(
            [str(qemu_img), "--version"], text=True
        ).splitlines()[0]
    except (OSError, subprocess.CalledProcessError, IndexError) as error:
        return None, [f"cannot read QEMU tool versions: {error}"]
    return Toolchain(
        qemu,
        profile.architecture,
        qemu_img,
        qemu_version,
        sha256_file(qemu),
        qemu_img_version,
        sha256_file(qemu_img),
    ), []


def qemu_binary(workspace: Path, architecture: str) -> Path | None:
    requested = (
        os.environ.get("COSIM_IMAGE_QEMU_BIN")
        or os.environ.get("QEMU_BIN")
    )
    candidates = []
    if requested:
        requested_path = Path(requested)
        if requested_path.is_absolute() or "/" in requested:
            candidates.append(
                requested_path
                if requested_path.is_absolute()
                else workspace / requested_path
            )
        else:
            selected = shutil.which(requested)
            if selected:
                return Path(selected).resolve()
    target = {
        "x86_64": "x86_64",
        "aarch64": "aarch64",
        "riscv64": "riscv64",
    }[architecture]
    binary = f"qemu-system-{target}"
    candidates.extend([workspace / "build/qemu" / binary, Path(binary)])
    for candidate in candidates:
        selected = (
            shutil.which(str(candidate))
            if not candidate.is_absolute()
            else str(candidate)
        )
        if (
            selected
            and Path(selected).is_file()
            and os.access(selected, os.X_OK)
        ):
            return Path(selected).resolve()
    return None


def qemu_img_binary(workspace: Path) -> Path | None:
    requested = (
        os.environ.get("COSIM_IMAGE_QEMU_IMG")
        or os.environ.get("QEMU_IMG")
    )
    candidates = []
    if requested:
        requested_path = Path(requested)
        if requested_path.is_absolute() or "/" in requested:
            candidates.append(
                requested_path
                if requested_path.is_absolute()
                else workspace / requested_path
            )
        else:
            selected = shutil.which(requested)
            if selected:
                return Path(selected).resolve()
    candidates.extend([workspace / "build/qemu/qemu-img", Path("qemu-img")])
    for candidate in candidates:
        selected = (
            shutil.which(str(candidate))
            if not candidate.is_absolute()
            else str(candidate)
        )
        if (
            selected
            and Path(selected).is_file()
            and os.access(selected, os.X_OK)
        ):
            return Path(selected).resolve()
    return None


def packer_variables(
    workspace: Path,
    profile: ImageProfile,
    stage: Path,
    tools: Toolchain,
    ansible: Path,
    fetched: Path,
    ansible_temp: Path,
) -> dict:
    return {
        "profile_id": profile.identifier,
        "base_image": profile.base_url,
        "base_checksum": profile.base_sha256,
        "qemu_binary": str(tools.qemu),
        "output_directory": str(stage / "packer-output"),
        "image_name": profile.image_name,
        "disk_size": profile.disk_size,
        "disk_format": profile.disk_format,
        "builder_cpus": profile.cpus,
        "builder_memory": profile.memory_mb,
        "ssh_username": profile.ssh_username,
        "accelerator": profile.accelerator,
        "machine_type": profile.machine_type,
        "cpu_model": profile.cpu_model,
        "ansible_playbook": str(workspace / ANSIBLE_ROOT / "provision.yml"),
        "ansible_command": str(ansible),
        "ansible_tmp_dir": str(ansible_temp),
        "ansible_variables": ansible_variables(profile, fetched),
    }


def ansible_variables(profile: ImageProfile, fetched: Path) -> dict:
    return {
        "cosim_profile_tasks": str(profile.tasks_file),
        "cosim_profile_variables": profile.variables,
        "cosim_inputs": {
            name: str(path.resolve())
            for name, path in profile.inputs.items()
        },
        "cosim_outputs": [asdict(output) for output in profile.outputs],
        "cosim_output_directory": str(fetched),
    }


def validate_ansible(
    workspace: Path,
    profile: ImageProfile,
    ansible: Path,
) -> None:
    output_directory = workspace / "build/images/.ansible-syntax"
    output_directory.mkdir(parents=True, exist_ok=True)
    variables = json.dumps(ansible_variables(profile, output_directory))
    run_logged(
        [
            str(ansible),
            "--syntax-check",
            "--inventory",
            "default,",
            "--connection",
            "local",
            "--extra-vars",
            variables,
            str(workspace / ANSIBLE_ROOT / "provision.yml"),
        ],
        workspace,
        tool_environment(workspace),
        workspace / "build/logs/ansible-syntax.log",
    )


def ensure_packer(workspace: Path) -> Path:
    local = workspace / IMAGE_TOOL_DIR / "packer" / PACKER_VERSION / "packer"
    if local.is_file() and os.access(local, os.X_OK):
        if _version_text(local).startswith(f"Packer v{PACKER_VERSION}"):
            return local
    platform_name = (
        "linux" if platform.system() == "Linux"
        else "darwin" if platform.system() == "Darwin"
        else ""
    )
    machine = platform.machine().lower()
    architecture = (
        "amd64" if machine in {"x86_64", "amd64"}
        else "arm64" if machine in {"aarch64", "arm64"}
        else ""
    )
    if not platform_name or not architecture:
        raise ImageError(
            f"unsupported Packer host: {platform.system()} {platform.machine()}"
        )
    archive_name = f"packer_{PACKER_VERSION}_{platform_name}_{architecture}.zip"
    release = f"https://releases.hashicorp.com/packer/{PACKER_VERSION}"
    tool_dir = local.parent
    tool_dir.mkdir(parents=True, exist_ok=True)
    archive_path = tool_dir / archive_name
    sums_path = tool_dir / f"packer_{PACKER_VERSION}_SHA256SUMS"
    try:
        _download(f"{release}/{archive_name}", archive_path)
        _download(f"{release}/packer_{PACKER_VERSION}_SHA256SUMS", sums_path)
        expected = _checksum_for(sums_path, archive_name)
        if sha256_file(archive_path) != expected:
            archive_path.unlink(missing_ok=True)
            raise ImageError(
                f"Packer archive checksum mismatch: {archive_name}"
            )
        with zipfile.ZipFile(archive_path) as archive:
            local.write_bytes(archive.read("packer"))
        local.chmod(0o755)
    except (
        OSError,
        urllib.error.URLError,
        zipfile.BadZipFile,
        KeyError,
    ) as error:
        raise ImageError(
            f"cannot install Packer {PACKER_VERSION}: {error}"
        ) from error
    return local


def ensure_ansible(workspace: Path) -> Path:
    executable = ansible_executable(workspace)
    if executable.is_file() and os.access(executable, os.X_OK):
        if (
            f"ansible-playbook [core {ANSIBLE_CORE_VERSION}]"
            in _version_text(executable)
        ):
            return executable
    venv_dir = workspace / IMAGE_TOOL_DIR / "ansible" / ANSIBLE_CORE_VERSION
    python = shutil.which("python3")
    if python is None:
        raise ImageError(
            "python3 is required to install the pinned Ansible environment"
        )
    if not (venv_dir / "bin/python").is_file():
        venv_dir.parent.mkdir(parents=True, exist_ok=True)
        subprocess.run([python, "-m", "venv", str(venv_dir)], check=True)
    pip = venv_dir / "bin/pip"
    requirement = workspace / ANSIBLE_REQUIREMENTS
    subprocess.run([
        str(pip),
        "install",
        "--disable-pip-version-check",
        "--no-warn-script-location",
        "--requirement", str(requirement),
    ], check=True)
    executable = venv_dir / "bin/ansible-playbook"
    if (
        not executable.is_file()
        or f"ansible-playbook [core {ANSIBLE_CORE_VERSION}]"
        not in _version_text(executable)
    ):
        raise ImageError(
            f"Ansible Core {ANSIBLE_CORE_VERSION} was not installed correctly"
        )
    return executable


def ansible_executable(workspace: Path) -> Path:
    return (
        workspace / IMAGE_TOOL_DIR / "ansible"
        / ANSIBLE_CORE_VERSION / "bin/ansible-playbook"
    )


def tool_environment(workspace: Path) -> dict[str, str]:
    cache = workspace / "build/cache/packer"
    temp = workspace / "build/tmp/packer"
    plugins = cache / "plugins"
    cache.mkdir(parents=True, exist_ok=True)
    plugins.mkdir(parents=True, exist_ok=True)
    temp.mkdir(parents=True, exist_ok=True)
    return {
        **os.environ,
        "PACKER_CACHE_DIR": str(cache),
        "PACKER_PLUGIN_PATH": str(plugins),
        "PACKER_TMP_DIR": "build/tmp/packer",
        "TMPDIR": "build/tmp/packer",
        "CHECKPOINT_DISABLE": "1",
        "PYTHONDONTWRITEBYTECODE": "1",
    }


def _version_text(executable: Path) -> str:
    try:
        return subprocess.check_output(
            [str(executable), "--version"],
            text=True,
            stderr=subprocess.STDOUT,
        )
    except (OSError, subprocess.CalledProcessError) as error:
        raise ImageError(f"cannot run {executable}: {error}") from error


def _download(url: str, destination: Path) -> None:
    request = urllib.request.Request(
        url,
        headers={"User-Agent": "cosim-gpu-image-builder"},
    )
    with (
        urllib.request.urlopen(request, timeout=60) as response,
        destination.open("wb") as output,
    ):
        shutil.copyfileobj(response, output)


def _checksum_for(path: Path, filename: str) -> str:
    for line in path.read_text(encoding="utf-8").splitlines():
        fields = line.split()
        if len(fields) == 2 and fields[1].lstrip("*") == filename:
            if re.fullmatch(r"[0-9a-fA-F]{64}", fields[0]):
                return fields[0].lower()
    raise ImageError(f"checksum entry for {filename} is missing")
