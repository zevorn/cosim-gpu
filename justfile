# SPDX-License-Identifier: Apache-2.0
#
# Task runner for cosim-gpu, the bridge that boots an AI infrastructure
# learning environment in QEMU and backs its accelerators with simulated
# GPU, NPU and TPU models (gem5 MI300X is the GPU backend).
# Run `just` to list the recipes.

set shell := ["bash", "-euo", "pipefail", "-c"]
set positional-arguments

host_arch_input := env("COSIM_HOST_ARCH", arch())
host_arch := if host_arch_input == "aarch64" { "aarch64" } else if host_arch_input == "x86_64" { "x86_64" } else { error("COSIM_HOST_ARCH must be aarch64 or x86_64") }
container_platform := if host_arch == "aarch64" { "linux/arm64" } else { "linux/amd64" }
gem5_build_dir := env("GEM5_BUILD_DIR", "build/gem5/" + host_arch + "/VEGA_X86")
rocm_profile := "guest/ubuntu/24.04/x86_64/rocm7_0"
rocm_image_dir := "build/images/" + rocm_profile
dev_image := env("COSIM_DEV_IMAGE", "cosim-dev:local")
gpu_fs_image := env("GPU_APP_BUILD_IMAGE", "ghcr.io/gem5/gpu-fs:latest")
build_jobs := env("JOBS", num_cpus())
m5_abi := if host_arch == "aarch64" { "arm64" } else { "x86" }

# Recipes that use {{ dev }} run on the host or in a temporary development
# container, as selected by COSIM_ENV.
export COSIM_ENV := env("COSIM_ENV", if os() == "linux" { "host" } else { "container" })
export COSIM_DEV_IMAGE := dev_image
export COSIM_DEV_PLATFORM := container_platform
dev := "scripts/dev.sh"

# List the available recipes
default:
    @just --list --unsorted

# ---------------------------------------------------------------------------
# Build
# ---------------------------------------------------------------------------

# Initialize the simulator and workload submodules
[group('dev')]
dev-submodules:
    git submodule update --init --recursive third_party/qemu third_party/gem5 third_party/gem5-resources

# Build the development container image
[group('dev')]
dev-image:
    docker build --platform {{ container_platform }} -t {{ dev_image }} -f scripts/Dockerfile.dev scripts

# Open a shell in a temporary development container
[group('dev')]
dev-shell:
    COSIM_ENV=container {{ dev }} --tty bash

# Build QEMU with KVM and vfio-user support
[group('build')]
build-qemu jobs=build_jobs:
    {{ dev }} scripts/build.sh qemu {{ host_arch }} "$1"

# Build gem5 (VEGA_X86); use jobs=1 if linking is OOM-killed
[group('build')]
build-gem5 jobs=build_jobs *scons_args:
    {{ dev }} scripts/build.sh gem5 {{ gem5_build_dir }} "$@"

# Build the m5 utility under the top-level build directory
[group('build')]
build-m5 abi=m5_abi: dev-rocm-sources
    {{ dev }} scripts/build.sh m5 "$1"

# Initialize missing image sources while preserving existing worktrees
[group('dev')]
dev-rocm-sources:
    if [ ! -e third_party/gem5/.git ]; then git submodule update --init third_party/gem5; fi
    if [ ! -e third_party/gem5-resources/.git ]; then git submodule update --init third_party/gem5-resources; fi

# Build the x86 guest disk image and kernel (needs Linux KVM, QEMU, ~60 GB disk)
[group('build')]
build-disk:
    just build-m5 x86
    scripts/cosim-image build {{ rocm_profile }}

# Build a reusable kernel/disk bundle from the guest image recipe library
[group('build')]
build-rocm-assets:
    just build-m5 x86
    scripts/cosim-image build {{ rocm_profile }}

# Prepare disk capacity and dependencies on a disposable CI image builder
[group('ci')]
ci-prepare-image-host:
    bash scripts/ci/prepare_image_host.sh

# Build a GPU application from third_party/gem5-resources/src/gpu
[group('build')]
build-gpu-app name="square":
    ./scripts/run_mi300x_fs.sh build-app "$1"

# Compile the HIP test kernels under tests/ in the ROCm container
[group('build')]
build-gpu-tests:
    mkdir -p "$PWD/build/tests"
    docker run --rm -u "$(id -u):$(id -g)" \
        -v "$PWD/tests:/tests" -v "$PWD/build/tests:/build" -w /tests \
        {{ gpu_fs_image }} make BUILDDIR=/build

# Build everything needed to launch co-simulation
[group('build')]
build-all: build-qemu build-gem5 build-m5 build-disk build-gpu-app build-cosim

# Build the topology launcher
[group('build')]
build-cosim:
    {{ dev }} cargo build --locked --release -p cosim-cli --bins

# Package the gem5 binary and the exact development image used to build it
[group('ci')]
ci-package-gem5 output:
    python3 scripts/ci/runtime_artifact.py package "$1" "{{ gem5_build_dir }}/gem5.opt"

# Identify the simulator source, tools, recipes and build job used by the cache
[group('ci')]
ci-gem5-key:
    python3 scripts/ci/runtime_artifact.py key

# Find a retained ROCm image from the same source repository and branch
[group('ci')]
ci-find-rocm-artifact key record:
    python3 -m scripts.ci.image_artifact find "$@"

# Publish a fully verified downloaded image into the build output directory
[group('ci')]
ci-adopt-rocm-artifact source output key:
    python3 -m scripts.ci.image_artifact adopt "$@"

# Remove only the failed download directory recorded by artifact selection
[group('ci')]
ci-discard-rocm-download record:
    python3 -m scripts.ci.image_artifact discard "$1"

# Validate the selected input identity and the complete downloaded image
[group('ci')]
ci-verify-rocm-artifact output key:
    {{ dev }} python3 -m scripts.ci.image_artifact verify "$@"

# Exercise image selection and isolation against actual published artifacts
[group('test')]
test-rocm-artifact key output:
    python3 -m scripts.ci.verify_image_artifact "$@"

# Republish a matching cached build while retaining original build provenance
[group('ci')]
ci-reuse-gem5 source output:
    python3 scripts/ci/runtime_artifact.py reuse "$@"

# Check cache invalidation, corruption rejection and original provenance
[group('test')]
test-ci-artifact source output:
    python3 scripts/ci/verify_runtime_artifact.py "$@"

# Restore a build from the same source revision and CI run
[group('ci')]
ci-restore-gem5 source:
    python3 scripts/ci/runtime_artifact.py restore "$1" "{{ gem5_build_dir }}/gem5.opt"

# Inspect the input key or verify a locally built ROCm kernel/disk bundle
[group('ci')]
ci-rocm-assets operation *args:
    scripts/cosim-image "$@"

# Validate the complete image configuration with real Packer plugins
[group('check')]
check-rocm-image:
    scripts/cosim-image validate {{ rocm_profile }}

# Check Packer HCL and Ansible syntax on a supported build host
[group('check')]
check-rocm-syntax:
    scripts/cosim-image validate {{ rocm_profile }} --syntax-only

# Check the resource scripts used by the image producer
[group('check')]
check-rocm-build-scripts:
    shellcheck scripts/cosim-image scripts/cosim_guest_setup.sh

# Exercise reuse and corruption rejection against a real built ROCm bundle
[group('test')]
test-rocm-assets output=rocm_image_dir:
    python3 -m scripts.ci.verify_rocm_assets "$1"

# Show which build artifacts are present
[group('build')]
build-status:
    ./scripts/run_mi300x_fs.sh status

# ---------------------------------------------------------------------------
# Run
# ---------------------------------------------------------------------------

# Launch a YAML topology
[group('run')]
run-topology topology="samples/machines/single-gpu.yaml" *args:
    {{ dev }} cargo run --locked --release -q -p cosim-cli -- run "$@"

# Launch a YAML topology with the development build
[group('run')]
run-topology-dev topology="samples/machines/single-gpu.yaml" *args:
    {{ dev }} cargo run --locked -q -p cosim-cli -- run "$@"

# Inspect or operate a topology through any cosim subcommand
[group('run')]
run-cli +args:
    {{ dev }} cargo run --locked -q -p cosim-cli -- "$@"

# Launch QEMU + gem5 co-simulation (options are passed to cosim_launch.sh)
[group('run')]
run-launch *args:
    ./scripts/cosim_launch.sh "$@"

# Run guest GPU tests in fresh co-simulation sessions (see run_cosim_tests.sh)
[group('test')]
test-gpu *args:
    ./scripts/run_cosim_tests.sh "$@"

# Run the ROCm regression suite with the built Rust launcher and verified assets
[group('test')]
test-rocm-regression output assets *args:
    {{ dev }} python3 scripts/ci/run_rocm.py "$@" --gem5 "{{ gem5_build_dir }}/gem5.opt" --qemu build/qemu/qemu-system-x86_64

# List co-simulation resources left on the host without changing them
[group('run')]
run-preflight:
    ./scripts/cosim_preflight.sh

# Delete orphaned co-simulation resources (sockets, shared memory, containers)
[group('run')]
run-clean-orphans:
    ./scripts/cosim_launch.sh --force-clean --confirm

# Run standalone gem5 full-system simulation with the stdlib config
[group('run')]
run-gem5-fs app="":
    ./scripts/run_mi300x_fs.sh run ${1:+"$1"}

# Run standalone gem5 full-system simulation with the legacy gpufs config
[group('run')]
run-gem5-fs-legacy app="":
    ./scripts/run_mi300x_fs.sh run-legacy ${1:+"$1"}

# ---------------------------------------------------------------------------
# Checks
# ---------------------------------------------------------------------------

# Check gem5 source regions, or entire explicit files, with its style tool
[group('check')]
[working-directory('third_party/gem5')]
check-gem5-style *files:
    if [ "$#" -gt 0 ]; then python3 util/style.py "$@" </dev/null; else python3 util/style.py -m $(git diff --name-only -- '*.cc' '*.hh' '*.py') </dev/null; fi

# Inspect gem5 Python formatting without modifying files
[group('check')]
[working-directory('third_party/gem5')]
check-gem5-python-format +files:
    python3 -m black --check --diff "$@"
    python3 -m isort --check-only --diff "$@"

# Inspect formatting of staged gem5 C++ changes without modifying files
[group('check')]
[working-directory('third_party/gem5')]
check-gem5-cxx-format:
    python3 util/run-git-clang-format.py --dry-run

# Run the gem5 pre-commit hooks for explicit files
[group('check')]
[working-directory('third_party/gem5')]
check-gem5-hooks +files:
    pre-commit run --files "$@"

# Validate a gem5 commit message with its repository hook
[group('check')]
[working-directory('third_party/gem5')]
check-gem5-message message:
    pre-commit run --hook-stage commit-msg --commit-msg-filename "$1"

# Validate the focused gem5 workflow
[group('check')]
check-gem5-ci:
    actionlint .github/workflows/build.yml third_party/gem5/.github/workflows/mi300x-ci.yaml

# Validate the build and regression workflow dependency graph
[group('check')]
check-ci:
    actionlint .github/workflows/build.yml .github/workflows/integration.yml .github/workflows/ci.yml .github/workflows/update-simulator-submodules.yml

# Exercise guest command completion and failure reporting using real shells
[group('test')]
test-ci:
    mkdir -p artifacts/ci-check/scratch
    {{ dev }} env TMPDIR="$PWD/artifacts/ci-check/scratch" python3 -m unittest discover -s scripts/ci -p 'test_*.py' -v

# Check the legacy build entry against the host's actual Docker daemon
[group('test')]
test-legacy-build-image output="artifacts/ci-check":
    python3 scripts/ci/verify_legacy_image.py "$1"

# Verify CI cancellation through the real Rust launcher and QEMU
[group('test')]
test-ci-integration: build-cosim
    {{ dev }} python3 -m unittest discover -s scripts/ci -p 'integration_*.py' -v

# Exercise MI300X pool ownership and its GPU_VIPER memory protocol
[group('test')]
test-gem5-mi300x output case="all":
    mkdir -p "$1"
    {{ dev }} --mount "$1" python3 third_party/gem5/tests/mi300x/verify.py --gem5 "{{ gem5_build_dir }}/gem5.opt" --output "$(cd "$1" && pwd)" --case "$2"

# Check Rust formatting, warnings and behavior
[group('check')]
check-cosim:
    {{ dev }} cargo fmt --all -- --check
    {{ dev }} cargo clippy --locked --workspace --all-targets -- -D warnings
    {{ dev }} cargo test --locked --workspace

# Inspect Rust formatting without modifying source files
[group('check')]
check-cosim-format:
    {{ dev }} cargo fmt --all -- --check

# Run the Rust tests; arguments are passed to cargo test
[group('test')]
test-cosim *args:
    {{ dev }} cargo test --locked --workspace "$@"

# Run sessions with real QEMU processes and disk images
[group('test')]
test-cosim-integration:
    {{ dev }} cargo test --locked -p cosim-cli --test sessions -- --ignored --skip vfio_user --skip bounded_memory_pool

# Verify competing sessions against a real, bounded shared-memory filesystem
[group('test')]
test-cosim-memory:
    mkdir -p build/dev-cache/memory/home build/dev-cache/memory/cargo build/tmp/memory-test
    docker run --rm --init --shm-size 96m --user "$(id -u):$(id -g)" \
        --volume "$PWD:$PWD" --workdir "$PWD" \
        --env HOME="$PWD/build/dev-cache/memory/home" \
        --env CARGO_HOME="$PWD/build/dev-cache/memory/cargo" \
        --env CARGO_TARGET_DIR="$PWD/build/cargo/container" \
        --env TMPDIR="$PWD/build/tmp/memory-test" \
        {{ dev_image }} cargo test --locked -p cosim-cli --test sessions \
        bounded_memory_pool -- --ignored --test-threads=1

# Run a QEMU host with a QEMU vfio-user device built by build-qemu
[group('test')]
test-cosim-vfio-user: dev-rocm-sources
    {{ dev }} cargo test --locked -p cosim-cli --test sessions -- --ignored vfio_user

# Run checkpatch.pl on every commit since BASE (default: merge base with origin/main)
[group('check')]
check-patch base="":
    ./scripts/check_patch.sh ${1:+"$1"}

# Check an uncommitted patch file before creating its signed commit
[group('check')]
check-patch-file patch:
    perl scripts/checkpatch.pl --no-signoff --no-tree "$1"

# Run ShellCheck on the shell scripts
[group('check')]
check-shell:
    shellcheck scripts/*.sh scripts/ci/*.sh tests/run_tests.sh tests/test_modprobe_params.sh

# Check that cosim modprobe commands carry the required amdgpu parameters
[group('check')]
check-modprobe-params:
    bash tests/test_modprobe_params.sh

# Validate MAINTAINERS.yml and require every tracked file to belong to an area
[group('check')]
check-maintainers:
    #!/usr/bin/env bash
    set -euo pipefail
    orphaned="$(python3 scripts/get_maintainer.py orphaned)"
    if [ -n "$orphaned" ]; then
        echo "Files not covered by any area in MAINTAINERS.yml:" >&2
        echo "$orphaned" >&2
        exit 1
    fi
    echo "MAINTAINERS.yml: valid, every tracked file belongs to an area"

# Run all host-side checks that need no submodules or KVM
[group('check')]
check: check-patch check-shell check-maintainers check-cosim

# ---------------------------------------------------------------------------
# Maintainers
# ---------------------------------------------------------------------------

# Show the areas, maintainers and collaborators for PATHs
[group('maint')]
maint-paths +paths:
    @python3 scripts/get_maintainer.py path "$@"

# Show the areas touched by a commit range (default: HEAD~..)
[group('maint')]
maint-commits range="HEAD~..":
    @python3 scripts/get_maintainer.py commits "$1"

# List all areas with their maintainers and collaborators
[group('maint')]
maint-areas:
    @python3 scripts/get_maintainer.py areas
