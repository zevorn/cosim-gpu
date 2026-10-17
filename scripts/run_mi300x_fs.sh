#!/bin/bash
# =============================================================================
# gem5 MI300X Full-System GPU Simulation - Setup & Run Script
#
# Adapted for the local development layout:
#   cosim-gpu/
#     third_party/gem5/         <- gem5 source
#     build/gem5/               <- gem5 build output
#     third_party/gem5-resources/ <- ROM and GPU app sources
#     scripts/                  <- this script
#
# Usage:
#   ./scripts/run_mi300x_fs.sh build-gem5          # Build gem5 via Docker
#   ./scripts/run_mi300x_fs.sh build-disk           # Build disk image (KVM)
#   ./scripts/run_mi300x_fs.sh build-app [name]     # Build GPU test app (default: square)
#   ./scripts/run_mi300x_fs.sh build-all            # Full setup from scratch
#   ./scripts/run_mi300x_fs.sh run [app]            # Run with stdlib config (KVM)
#   ./scripts/run_mi300x_fs.sh run-legacy [app]     # Run with legacy gpufs/mi300.py
#   ./scripts/run_mi300x_fs.sh status               # Show build status
# =============================================================================

set -euo pipefail

# ---- Path layout ----

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COSIM_DIR="$(dirname "$SCRIPT_DIR")"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/cosim_lib.sh"
GEM5_DIR="${COSIM_DIR}/third_party/gem5"
RESOURCES_DIR="${COSIM_DIR}/third_party/gem5-resources"

# Built artifacts (ROCm 7.0 disk image)
DISK_IMAGE_DIR="${COSIM_DIR}/build/images/guest/ubuntu/24.04/x86_64/rocm7_0"
DISK_IMAGE="${DISK_IMAGE_DIR}/disk"
KERNEL="${DISK_IMAGE_DIR}/kernel"
SQUARE_APP="${COSIM_DIR}/build/apps/square/square.default"
GEM5_BUILD_DIR="$(just --justfile "${COSIM_DIR}/justfile" \
    --evaluate gem5_build_dir)"
GEM5_BUILD_RELATIVE="$(cosim_gem5_build_dir "$COSIM_DIR" "$GEM5_BUILD_DIR")"
GEM5_BIN="${COSIM_DIR}/${GEM5_BUILD_RELATIVE}/gem5.opt"

# QEMU: $QEMU_BIN, else the qemu submodule build, else PATH
QEMU_SUBMODULE_BIN="${COSIM_DIR}/build/qemu/qemu-system-x86_64"
if [ -z "${QEMU_BIN:-}" ]; then
    if [ -x "$QEMU_SUBMODULE_BIN" ]; then
        QEMU_BIN="$QEMU_SUBMODULE_BIN"
    else
        QEMU_BIN="$(command -v qemu-system-x86_64 2>/dev/null || true)"
    fi
fi

# Logs

# Docker images
GEM5_BUILD_IMAGE="${GEM5_RUN_IMAGE:-cosim-dev:local}"
GPU_APP_BUILD_IMAGE="${GPU_APP_BUILD_IMAGE:-ghcr.io/gem5/gpu-fs}"

# gem5 config files
STDLIB_CONFIG="${GEM5_DIR}/configs/example/gem5_library/x86-mi300x-gpu.py"
LEGACY_CONFIG="${GEM5_DIR}/configs/example/gpufs/mi300.py"

# ---- Colors ----

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

# ---- Helpers ----

require_docker() {
    command -v docker >/dev/null || error "docker not found"
    docker info >/dev/null 2>&1 || error "Docker daemon not running. Try: sudo dockerd &"
}

check_kvm() {
    if [ -e /dev/kvm ]; then
        info "KVM available"
        return 0
    fi
    warn "KVM not available (/dev/kvm missing)"
    return 1
}

# Translate host path to container path (/gem5/...)
to_container_path() {
    case "$1" in
        "$GEM5_DIR"/*) echo "/gem5/${1#"$GEM5_DIR"/}" ;;
        "$COSIM_DIR"/build/*) echo "/build/${1#"$COSIM_DIR"/build/}" ;;
        *) echo "$1" ;;
    esac
}

# Run gem5 binary inside Docker (Ubuntu 24.04 deps) with KVM passthrough
run_gem5_docker() {
    require_docker
    local docker_args=("--rm" "-u" "$(id -u):$(id -g)"
        "-v" "${GEM5_DIR}:/gem5" "-v" "${COSIM_DIR}/build:/build" "-w" "/gem5"
        "-e" "PYTHONPATH=/usr/lib/python3.12/lib-dynload"
        "-p" "3456:3456" "-p" "7000:7000")
    if [ -e /dev/kvm ]; then
        docker_args+=("--device" "/dev/kvm")
    fi
    docker run "${docker_args[@]}" "${GEM5_RUN_IMAGE:-cosim-dev:local}" "$@"
}

# ==========================
# Build gem5 (via Docker)
# ==========================
build_gem5() {
    info "Building gem5 (VEGA_X86) via Docker..."

    if [ -f "$GEM5_BIN" ]; then
        info "gem5 binary already exists: $GEM5_BIN"
        read -p "Rebuild? [y/N] " -n 1 -r
        echo
        [[ ! $REPLY =~ ^[Yy]$ ]] && return 0
    fi

    require_docker

    local nproc_val
    nproc_val="$(nproc)"

    info "Using image: $GEM5_BUILD_IMAGE"
    info "Build parallelism: -j${nproc_val}"
    COSIM_ENV=container COSIM_DEV_IMAGE="$GEM5_BUILD_IMAGE" \
        just --justfile "${COSIM_DIR}/justfile" build-gem5 "$nproc_val"

    [ -f "$GEM5_BIN" ] || error "gem5 build failed"
    info "gem5 built: $GEM5_BIN"
}

# ==========================
# Get gem5-resources
# ==========================
get_resources() {
    if [ -e "${RESOURCES_DIR}/.git" ]; then
        info "gem5-resources exists: $RESOURCES_DIR"
        return 0
    fi

    info "Initializing gem5-resources submodule..."
    git -C "$COSIM_DIR" submodule update --init third_party/gem5-resources
    info "gem5-resources initialized"
}

# ==========================
# Build disk image
# ==========================
build_disk_image() {
    info "Building disk image (Ubuntu 24.04 + ROCm)..."
    info "This takes ~30 min and needs ~60GB disk space"
    just --justfile "${COSIM_DIR}/justfile" build-disk
    [ -f "$DISK_IMAGE" ] || error "Disk image build failed"
    info "Disk image: $DISK_IMAGE"
    info "Kernel:     $KERNEL"
}

# ==========================
# Build GPU test app
# ==========================
build_gpu_app() {
    local app_name="${1:-square}"
    local app_src="${RESOURCES_DIR}/src/gpu/${app_name}"
    local app_output="${COSIM_DIR}/build/apps/${app_name}"
    local app_bin="${app_output}/${app_name}.default"

    info "Building GPU app: ${app_name}..."

    [ -d "$app_src" ] || error "App source not found: $app_src"

    if [ -f "$app_bin" ]; then
        info "App already built: $app_bin"
        return 0
    fi

    if command -v docker >/dev/null && docker info >/dev/null 2>&1; then
        info "Building via Docker (${GPU_APP_BUILD_IMAGE})..."
        mkdir -p "$app_output"
        docker run --rm \
            -u "$(id -u):$(id -g)" \
            -v "${COSIM_DIR}:${COSIM_DIR}" \
            -w "${app_src}" \
            "$GPU_APP_BUILD_IMAGE" \
            make -f Makefile.default "BIN_DIR=${app_output}"
    elif command -v hipcc >/dev/null; then
        info "Building with local hipcc..."
        mkdir -p "$app_output"
        make -C "$app_src" -f Makefile.default "BIN_DIR=${app_output}"
    else
        error "Need Docker or hipcc (ROCm) to build GPU apps"
    fi

    [ -f "$app_bin" ] || error "GPU app build failed"
    info "GPU app built: $app_bin"
}

# ==========================
# Run: stdlib config
# ==========================
run_simulation() {
    local app="${1:-}"

    info "Running MI300X FS simulation (stdlib config)"

    [ -f "$GEM5_BIN" ]   || error "gem5 not built. Run: just build-gem5"
    [ -f "$STDLIB_CONFIG" ] || error "Config missing: $STDLIB_CONFIG"
    [ -f "$DISK_IMAGE" ] || error "Disk image missing. Run: just build-disk"
    [ -f "$KERNEL" ]     || error "Kernel missing. Run: just build-disk"
    check_kvm            || error "KVM required. The stdlib config uses KvmCPU."

    local app_args=()
    if [ -n "$app" ]; then
        [ -f "$app" ] || error "App not found: $app. Run: just build-gpu-app"
        info "  App: $app"
        app_args=("--app" "$(to_container_path "$app")")
    else
        info "  No GPU app specified, booting guest Linux only"
    fi

    cd "$GEM5_DIR"
    info "Starting gem5 via Docker... (output: m5out/system.pc.com_1.device)"

    run_gem5_docker \
        "$(to_container_path "$GEM5_BIN")" \
        --listener-mode=on \
        "$(to_container_path "$STDLIB_CONFIG")" \
        --image "$(to_container_path "$DISK_IMAGE")" \
        --kernel "$(to_container_path "$KERNEL")" \
        "${app_args[@]}"

    info "Simulation complete."
    echo "========================================"
    cat m5out/system.pc.com_1.device 2>/dev/null || warn "No output file"
    echo "========================================"
}

# ==========================
# Run: legacy gpufs/mi300.py
# ==========================
run_simulation_legacy() {
    local app="${1:-$SQUARE_APP}"

    info "Running MI300X FS simulation (legacy config)"
    info "  App: $app"

    [ -f "$GEM5_BIN" ]   || error "gem5 not built. Run: just build-gem5"
    [ -f "$LEGACY_CONFIG" ] || error "Config missing: $LEGACY_CONFIG"
    [ -f "$DISK_IMAGE" ] || error "Disk image missing. Run: just build-disk"
    [ -f "$KERNEL" ]     || error "Kernel missing. Run: just build-disk"
    [ -f "$app" ]        || error "App not found: $app. Run: just build-gpu-app"
    check_kvm            || error "KVM required. Legacy config uses X86KvmCPU."

    cd "$GEM5_DIR"
    info "Starting gem5 via Docker..."

    run_gem5_docker \
        "$(to_container_path "$GEM5_BIN")" \
        --listener-mode=on \
        "$(to_container_path "$LEGACY_CONFIG")" \
        --disk-image "$(to_container_path "$DISK_IMAGE")" \
        --kernel "$(to_container_path "$KERNEL")" \
        -a "$(to_container_path "$app")"
}

# ==========================
# Status
# ==========================
show_status() {
    echo "=== gem5 MI300X FS Status ==="
    echo ""

    # gem5 binary
    if [ -f "$GEM5_BIN" ]; then
        info "gem5 binary:     $GEM5_BIN"
    else
        warn "gem5 binary:     MISSING (run: just build-gem5)"
    fi

    # gem5-resources
    if [ -d "$RESOURCES_DIR" ]; then
        info "gem5-resources:  $RESOURCES_DIR"
    else
        warn "gem5-resources:  MISSING (run: just build-all)"
    fi

    # Disk image
    if [ -f "$DISK_IMAGE" ]; then
        local size
        size="$(du -h "$DISK_IMAGE" | cut -f1)"
        info "Disk image:      $DISK_IMAGE (${size})"
    else
        warn "Disk image:      MISSING (run: just build-disk)"
    fi

    # Kernel
    if [ -f "$KERNEL" ]; then
        info "Kernel:          $KERNEL"
    else
        warn "Kernel:          MISSING (run: just build-disk)"
    fi

    # Square app
    if [ -f "$SQUARE_APP" ]; then
        info "Square app:      $SQUARE_APP"
    else
        warn "Square app:      MISSING (run: just build-gpu-app)"
    fi

    echo ""
    echo "=== Environment ==="

    # KVM
    check_kvm 2>/dev/null || true

    # Docker
    if command -v docker >/dev/null && docker info >/dev/null 2>&1; then
        info "Docker:          running"
        # Check for the development image (also used by legacy launch)
        local run_image="${GEM5_RUN_IMAGE:-cosim-dev:local}"
        if docker image inspect "$run_image" >/dev/null 2>&1; then
            info "  Runtime image: $run_image"
        else
            warn "  Runtime image: $run_image" \
                 "(not built, run: just dev-image)"
        fi
        if docker image inspect "$GPU_APP_BUILD_IMAGE" >/dev/null 2>&1; then
            info "  GPU app image: $GPU_APP_BUILD_IMAGE"
        else
            warn "  GPU app image: $GPU_APP_BUILD_IMAGE (not pulled)"
        fi
    elif command -v docker >/dev/null; then
        warn "Docker:          installed but daemon not running"
    else
        warn "Docker:          not installed"
    fi

    # QEMU
    if [ -n "$QEMU_BIN" ] && [ -x "$QEMU_BIN" ]; then
        info "QEMU binary:     $QEMU_BIN"
    else
        warn "QEMU binary:     not found" \
             "(run: just build-qemu, or set QEMU_BIN)"
    fi
}

# ==========================
# Main
# ==========================
usage() {
    cat <<USAGE
gem5 MI300X Full-System GPU Simulation

Commands:
  build-gem5         Build gem5 (VEGA_X86) via Docker
  build-disk         Build disk image (Ubuntu 22.04 + ROCm)
  build-app [name]   Build GPU test app (default: square)
  build-all          Full setup: gem5 + disk image + GPU app
  run [app]          Run with stdlib config (x86-mi300x-gpu.py)
  run-legacy [app]   Run with legacy config (gpufs/mi300.py)
  status             Show build status

Environment variables:
  GPU_APP_BUILD_IMAGE  Docker image for GPU app build
                     (default: $GPU_APP_BUILD_IMAGE)
  QEMU_BIN            QEMU binary used to build the disk image
                     (default: build/qemu/qemu-system-x86_64, else PATH)

Layout:
  gem5 source:       $GEM5_DIR
  gem5-resources:    $RESOURCES_DIR
  Disk image:        $DISK_IMAGE
  Kernel:            $KERNEL
  Square app:        $SQUARE_APP

Quick start (just recipes, see \`just --list\`):
  just build-all
  just run-gem5-fs
USAGE
}

main() {
    local cmd="${1:-help}"
    shift || true

    case "$cmd" in
        build-all)
            build_gem5
            get_resources
            build_disk_image
            build_gpu_app "${1:-square}"
            info "All components built!"
            info "Run: just run-gem5-fs"
            ;;
        build-gem5)
            build_gem5
            ;;
        build-disk)
            get_resources
            build_disk_image
            ;;
        build-app)
            get_resources
            build_gpu_app "${1:-square}"
            ;;
        run)
            run_simulation "${1:-}"
            ;;
        run-legacy)
            run_simulation_legacy "${1:-$SQUARE_APP}"
            ;;
        status)
            show_status
            ;;
        help|*)
            usage
            ;;
    esac
}

main "$@"
