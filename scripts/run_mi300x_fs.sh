#!/bin/bash
# =============================================================================
# gem5 MI300X Full-System GPU Simulation - Setup & Run Script
#
# Adapted for the local development layout:
#   /home/zevorn/cosim/
#     gem5/                     <- gem5 source & build
#     gem5-resources/           <- disk image, kernel, GPU apps
#     scripts/                  <- this script
#     qemu/                     <- QEMU source (for cosim mode)
#
# Usage:
#   ./scripts/run_mi300x_fs.sh build-gem5          # Build gem5 via Docker
#   ./scripts/run_mi300x_fs.sh build-qemu          # Build QEMU (mi300x-gem5 cosim device)
#   ./scripts/run_mi300x_fs.sh build-disk           # Build disk image (needs KVM + qemu)
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
GEM5_DIR="${COSIM_DIR}/gem5"
RESOURCES_DIR="${COSIM_DIR}/gem5-resources"

# Built artifacts (ROCm 7.0 disk image)
DISK_IMAGE_DIR="${RESOURCES_DIR}/src/x86-ubuntu-gpu-ml/disk-image"
DISK_IMAGE="${DISK_IMAGE_DIR}/x86-ubuntu-rocm70"
KERNEL="${RESOURCES_DIR}/src/x86-ubuntu-gpu-ml/vmlinux-rocm70"
SQUARE_APP="${RESOURCES_DIR}/src/gpu/square/bin.default/square.default"
GEM5_BIN="${GEM5_DIR}/build/VEGA_X86/gem5.opt"

# QEMU
QEMU_DIR="${COSIM_DIR}/qemu"
QEMU_BUILD_DIR="${QEMU_DIR}/build"
QEMU_BIN="${QEMU_BUILD_DIR}/qemu-system-x86_64"

# Docker images
GEM5_BUILD_IMAGE="${GEM5_BUILD_IMAGE:-ghcr.io/gem5/ubuntu-24.04_all-dependencies:v24-0}"
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
    echo "${1/$GEM5_DIR//gem5}"
}

# Run gem5 binary inside Docker (Ubuntu 24.04 deps) with KVM passthrough
run_gem5_docker() {
    require_docker
    local docker_args=("--rm" "-u" "$(id -u):$(id -g)"
        "-v" "${GEM5_DIR}:/gem5" "-w" "/gem5"
        "-e" "PYTHONPATH=/usr/lib/python3.12/lib-dynload"
        "-p" "3456:3456" "-p" "7000:7000")
    if [ -e /dev/kvm ]; then
        docker_args+=("--device" "/dev/kvm")
    fi
    docker run "${docker_args[@]}" "${GEM5_RUN_IMAGE:-gem5-run:local}" "$@"
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

    docker run --rm \
        -v "${GEM5_DIR}:/gem5" \
        -w /gem5 \
        "$GEM5_BUILD_IMAGE" \
        scons build/VEGA_X86/gem5.opt -j"${nproc_val}"

    [ -f "$GEM5_BIN" ] || error "gem5 build failed"
    info "gem5 built: $GEM5_BIN"
}

# ==========================
# Build QEMU (with mi300x-gem5 cosim device)
# ==========================
build_qemu() {
    info "Building QEMU (x86_64-softmmu) with mi300x-gem5 device..."

    [ -d "$QEMU_DIR" ] || error "QEMU source not found: $QEMU_DIR"

    if [ -f "$QEMU_BIN" ]; then
        info "QEMU binary already exists: $QEMU_BIN"
        read -p "Rebuild? [y/N] " -n 1 -r
        echo
        [[ ! $REPLY =~ ^[Yy]$ ]] && return 0
    fi

    mkdir -p "$QEMU_BUILD_DIR"
    cd "$QEMU_BUILD_DIR"

    if [ ! -f "$QEMU_BUILD_DIR/build.ninja" ]; then
        info "Configuring QEMU..."
        "${QEMU_DIR}/configure" --target-list=x86_64-softmmu
    fi

    local nproc_val
    nproc_val="$(nproc)"
    info "Build parallelism: -j${nproc_val}"

    make -j"${nproc_val}"

    [ -f "$QEMU_BIN" ] || error "QEMU build failed"
    info "QEMU built: $QEMU_BIN"
}

# ==========================
# Get gem5-resources
# ==========================
get_resources() {
    if [ -d "$RESOURCES_DIR" ]; then
        info "gem5-resources exists: $RESOURCES_DIR"
        return 0
    fi

    info "Cloning gem5-resources..."
    git clone --depth 1 https://github.com/gem5/gem5-resources.git "$RESOURCES_DIR"
    info "gem5-resources cloned"
}

# ==========================
# Build disk image
# ==========================
build_disk_image() {
    info "Building disk image (Ubuntu 22.04 + ROCm)..."
    info "This takes ~30 min and needs ~60GB disk space"

    command -v qemu-system-x86_64 >/dev/null || \
        error "qemu-system-x86_64 not found. Install: sudo apt install qemu-system-x86"
    command -v unzip >/dev/null || \
        error "unzip not found. Install: sudo apt install unzip"
    check_kvm || error "KVM required for disk image build"

    if [ -f "$DISK_IMAGE" ]; then
        info "Disk image exists: $DISK_IMAGE"
        read -p "Rebuild? [y/N] " -n 1 -r
        echo
        [[ ! $REPLY =~ ^[Yy]$ ]] && return 0
    fi

    cd "${RESOURCES_DIR}/src/x86-ubuntu-gpu-ml"
    ./build.sh

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
    local app_bin="${app_src}/bin.default/${app_name}.default"

    info "Building GPU app: ${app_name}..."

    [ -d "$app_src" ] || error "App source not found: $app_src"

    if [ -f "$app_bin" ]; then
        info "App already built: $app_bin"
        return 0
    fi

    if command -v docker >/dev/null && docker info >/dev/null 2>&1; then
        info "Building via Docker (${GPU_APP_BUILD_IMAGE})..."
        docker run --rm \
            -u "$(id -u):$(id -g)" \
            -v "${app_src}:${app_src}" \
            -w "${app_src}" \
            "$GPU_APP_BUILD_IMAGE" \
            make -f Makefile.default
    elif command -v hipcc >/dev/null; then
        info "Building with local hipcc..."
        make -C "$app_src" -f Makefile.default
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

    [ -f "$GEM5_BIN" ]   || error "gem5 not built. Run: $0 build-gem5"
    [ -f "$STDLIB_CONFIG" ] || error "Config missing: $STDLIB_CONFIG"
    [ -f "$DISK_IMAGE" ] || error "Disk image missing. Run: $0 build-disk"
    [ -f "$KERNEL" ]     || error "Kernel missing. Run: $0 build-disk"
    check_kvm            || error "KVM required. The stdlib config uses KvmCPU."

    local app_args=()
    if [ -n "$app" ]; then
        [ -f "$app" ] || error "App not found: $app. Run: $0 build-app"
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

    [ -f "$GEM5_BIN" ]   || error "gem5 not built. Run: $0 build-gem5"
    [ -f "$LEGACY_CONFIG" ] || error "Config missing: $LEGACY_CONFIG"
    [ -f "$DISK_IMAGE" ] || error "Disk image missing. Run: $0 build-disk"
    [ -f "$KERNEL" ]     || error "Kernel missing. Run: $0 build-disk"
    [ -f "$app" ]        || error "App not found: $app. Run: $0 build-app"
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
        warn "gem5 binary:     MISSING (run: $0 build-gem5)"
    fi

    # gem5-resources
    if [ -d "$RESOURCES_DIR" ]; then
        info "gem5-resources:  $RESOURCES_DIR"
    else
        warn "gem5-resources:  MISSING (run: $0 build-all)"
    fi

    # Disk image
    if [ -f "$DISK_IMAGE" ]; then
        local size
        size="$(du -h "$DISK_IMAGE" | cut -f1)"
        info "Disk image:      $DISK_IMAGE (${size})"
    else
        warn "Disk image:      MISSING (run: $0 build-disk)"
    fi

    # Kernel
    if [ -f "$KERNEL" ]; then
        info "Kernel:          $KERNEL"
    else
        warn "Kernel:          MISSING (run: $0 build-disk)"
    fi

    # Square app
    if [ -f "$SQUARE_APP" ]; then
        info "Square app:      $SQUARE_APP"
    else
        warn "Square app:      MISSING (run: $0 build-app)"
    fi

    echo ""
    echo "=== Environment ==="

    # KVM
    check_kvm 2>/dev/null || true

    # Docker
    if command -v docker >/dev/null && docker info >/dev/null 2>&1; then
        info "Docker:          running"
        # Check for build images
        if docker image inspect "$GEM5_BUILD_IMAGE" >/dev/null 2>&1; then
            info "  Build image:   $GEM5_BUILD_IMAGE"
        else
            warn "  Build image:   $GEM5_BUILD_IMAGE (not pulled)"
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
    if [ -f "$QEMU_BIN" ]; then
        info "QEMU binary:     $QEMU_BIN"
    elif [ -d "$QEMU_DIR" ]; then
        warn "QEMU binary:     NOT BUILT (run: $0 build-qemu)"
        info "  QEMU source:   $QEMU_DIR"
    else
        warn "QEMU source:     not found at $QEMU_DIR"
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
  build-qemu         Build QEMU (x86_64-softmmu, with mi300x-gem5 device)
  build-disk         Build disk image (Ubuntu 22.04 + ROCm)
  build-app [name]   Build GPU test app (default: square)
  build-all          Full setup: gem5 + QEMU + disk image + GPU app
  run [app]          Run with stdlib config (x86-mi300x-gpu.py)
  run-legacy [app]   Run with legacy config (gpufs/mi300.py)
  status             Show build status

Environment variables:
  GEM5_BUILD_IMAGE   Docker image for gem5 build
                     (default: $GEM5_BUILD_IMAGE)
  GPU_APP_BUILD_IMAGE  Docker image for GPU app build
                     (default: $GPU_APP_BUILD_IMAGE)

Layout:
  gem5 source:       $GEM5_DIR
  QEMU source:       $QEMU_DIR
  gem5-resources:    $RESOURCES_DIR
  Disk image:        $DISK_IMAGE
  Kernel:            $KERNEL
  Square app:        $SQUARE_APP

Quick start:
  $0 build-all
  $0 run
USAGE
}

main() {
    local cmd="${1:-help}"
    shift || true

    case "$cmd" in
        build-all)
            build_gem5
            build_qemu
            get_resources
            build_disk_image
            build_gpu_app "${1:-square}"
            info "All components built!"
            info "Run: $0 run"
            ;;
        build-gem5)
            build_gem5
            ;;
        build-qemu)
            build_qemu
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
