#!/bin/bash
# ==========================================================================
# QEMU + gem5 MI300X Co-simulation Launcher
#
# gem5 runs inside Docker (GPU-only, no kernel), QEMU runs on the host
# with KVM.  Two backends are supported:
#
#   vfio-user (default): Standard vfio-user protocol via libvfio-user.
#     QEMU uses upstream vfio-user-pci — no custom QEMU code needed.
#
#   legacy: Custom cosim socket protocol with QEMU's mi300x-gem5 device.
#
# Usage:
#   ./scripts/cosim_launch.sh                              # vfio-user
#   ./scripts/cosim_launch.sh --cosim-backend legacy       # legacy
#   ./scripts/cosim_launch.sh --gem5-debug MI300XCosim      # with debug
#   ./scripts/cosim_launch.sh --help
# ==========================================================================

set -euo pipefail

# ---- Path defaults ----

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COSIM_DIR="$(dirname "$SCRIPT_DIR")"
GEM5_DIR="${COSIM_DIR}/gem5"
RESOURCES_DIR="${COSIM_DIR}/gem5-resources"

GEM5_BIN="${GEM5_DIR}/build/VEGA_X86/gem5.opt"
GEM5_CONFIG="${GEM5_DIR}/configs/example/gpufs/mi300_cosim.py"
GEM5_DOCKER_IMAGE="${GEM5_DOCKER_IMAGE:-gem5-run:local}"
GEM5_CONTAINER="gem5-cosim"

QEMU_BIN="${COSIM_DIR}/qemu/build/qemu-system-x86_64"
DISK_IMAGE="${RESOURCES_DIR}/src/x86-ubuntu-gpu-ml/disk-image/x86-ubuntu-rocm70"
KERNEL="${RESOURCES_DIR}/src/x86-ubuntu-gpu-ml/vmlinux-rocm70"
GPU_ROM="${RESOURCES_DIR}/src/x86-ubuntu-gpu-ml/files/mi300.rom"

SOCKET_PATH="/tmp/gem5-mi300x.sock"
SHMEM_PATH="/mi300x-vram"
SHMEM_HOST_PATH="/cosim-guest-ram"

HOST_MEM="8G"
HOST_CPUS="4"
VRAM_SIZE="16GiB"
NUM_CUS="40"
GEM5_DEBUG=""
GEM5_TIMEOUT=120
QEMU_TRACE=""
SHARE_DIR=""
COSIM_BACKEND="vfio-user"

# ---- Colors ----

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }
step()  { echo -e "${CYAN}[STEP]${NC} $*"; }

# ---- Argument parsing ----

usage() {
    cat <<EOF
QEMU + gem5 MI300X Co-simulation Launcher

Usage: $0 [options]

Options:
  --disk-image PATH       Disk image  (default: auto-detect in gem5-resources)
  --kernel PATH           vmlinux     (default: auto-detect in gem5-resources)
  --qemu-bin PATH         QEMU binary (default: ../qemu/build/qemu-system-x86_64)
  --gem5-bin PATH         gem5 binary (default: build/VEGA_X86/gem5.opt)
  --gem5-docker IMAGE     Docker image for gem5 (default: gem5-run:local)
  --socket-path PATH      Unix socket (default: /tmp/gem5-mi300x.sock)
  --host-mem SIZE         Guest RAM   (default: 8G)
  --host-cpus N           Guest CPUs  (default: 4)
  --vram-size SIZE        GPU VRAM    (default: 16GiB)
  --num-cus N             Compute units (default: 40)
  --gem5-debug FLAGS      gem5 debug flags (e.g. MI300XCosim,AMDGPUDevice)
  --qemu-trace EVENTS     QEMU trace events (e.g. mi300x_gem5_*)
  --share-dir PATH        Share host dir with guest via 9p (mount tag: cosim_share)
  --cosim-backend MODE    vfio-user (default) or legacy
  --timeout SECS          gem5 init timeout (default: 120)
  -h, --help              Show this help
EOF
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --disk-image)    DISK_IMAGE="$2";       shift 2 ;;
        --kernel)        KERNEL="$2";           shift 2 ;;
        --qemu-bin)      QEMU_BIN="$2";         shift 2 ;;
        --gem5-bin)      GEM5_BIN="$2";         shift 2 ;;
        --gem5-docker)   GEM5_DOCKER_IMAGE="$2"; shift 2 ;;
        --socket-path)   SOCKET_PATH="$2";      shift 2 ;;
        --host-mem)      HOST_MEM="$2";         shift 2 ;;
        --host-cpus)     HOST_CPUS="$2";        shift 2 ;;
        --vram-size)     VRAM_SIZE="$2";        shift 2 ;;
        --num-cus)       NUM_CUS="$2";          shift 2 ;;
        --gem5-debug)    GEM5_DEBUG="$2";       shift 2 ;;
        --qemu-trace)    QEMU_TRACE="$2";       shift 2 ;;
        --share-dir)     SHARE_DIR="$2";        shift 2 ;;
        --cosim-backend) COSIM_BACKEND="$2";   shift 2 ;;
        --timeout)       GEM5_TIMEOUT="$2";     shift 2 ;;
        -h|--help)       usage ;;
        *)               echo "Unknown option: $1"; usage ;;
    esac
done

# ---- Derived paths ----

SHMEM_FILE="/dev/shm${SHMEM_PATH}"
SHMEM_HOST_FILE="/dev/shm${SHMEM_HOST_PATH}"

# Container paths (gem5 source mounted at /gem5)
C_GEM5_BIN="/gem5/build/VEGA_X86/gem5.opt"
C_GEM5_CONFIG="/gem5/configs/example/gpufs/mi300_cosim.py"

# ---- Validation ----

[[ -f "$GEM5_BIN" ]]   || error "gem5 not found: $GEM5_BIN\n  Build: scons build/VEGA_X86/gem5.opt -j\$(nproc)"
[[ -f "$QEMU_BIN" ]]   || error "QEMU not found: $QEMU_BIN\n  Build: cd ../qemu && mkdir -p build && cd build && ../configure --target-list=x86_64-softmmu && make -j\$(nproc)"
[[ -f "$DISK_IMAGE" ]] || error "Disk image not found: $DISK_IMAGE\n  Build: ./scripts/run_mi300x_fs.sh build-disk"
[[ -f "$KERNEL" ]]     || error "Kernel not found: $KERNEL\n  Build: ./scripts/run_mi300x_fs.sh build-disk"
[[ -f "$GPU_ROM" ]]    || error "GPU ROM not found: $GPU_ROM"
[[ -r /dev/kvm ]]      || error "/dev/kvm not available. KVM is required for QEMU."

docker info >/dev/null 2>&1 || error "Docker not running"
docker image inspect "$GEM5_DOCKER_IMAGE" >/dev/null 2>&1 || \
    error "Docker image '$GEM5_DOCKER_IMAGE' not found.\n  Build: cd scripts && docker build -t gem5-run:local -f Dockerfile.run ."

# ---- Cleanup handler ----

cleanup() {
    echo ""
    info "Shutting down co-simulation..."
    docker rm -f "$GEM5_CONTAINER" >/dev/null 2>&1 || true
    rm -f "$SHMEM_FILE" "$SHMEM_HOST_FILE" 2>/dev/null || true
    # socket is owned by root (Docker), may fail — that's fine
    rm -f "$SOCKET_PATH" 2>/dev/null || true
    info "Done."
}
trap cleanup EXIT INT TERM

# ---- Clean up stale state ----

docker rm -f "$GEM5_CONTAINER" >/dev/null 2>&1 || true
rm -f "$SHMEM_FILE" "$SHMEM_HOST_FILE" 2>/dev/null || true
rm -f "$SOCKET_PATH" 2>/dev/null || true

# ==================================================================
# Step 1: Start gem5 in Docker
# ==================================================================

step "Starting gem5 MI300X GPU model in Docker..."

GEM5_DOCKER_CMD=(
    docker run -d --rm
    --name "$GEM5_CONTAINER"
    --user "$(id -u):$(id -g)"
    -v "${GEM5_DIR}:/gem5"
    -v /tmp:/tmp
    -v /dev/shm:/dev/shm
    -w /gem5
    -e "PYTHONPATH=/usr/lib/python3.12/lib-dynload"
    "$GEM5_DOCKER_IMAGE"
    "$C_GEM5_BIN"
)

if [[ -n "$GEM5_DEBUG" ]]; then
    GEM5_DOCKER_CMD+=("--debug-flags=$GEM5_DEBUG")
fi

GEM5_DOCKER_CMD+=(
    --listener-mode=on
    "$C_GEM5_CONFIG"
    "--socket-path=$SOCKET_PATH"
    "--shmem-path=$SHMEM_PATH"
    "--shmem-host-path=$SHMEM_HOST_PATH"
    "--dgpu-mem-size=$VRAM_SIZE"
    "--num-compute-units=$NUM_CUS"
    "--mem-size=$HOST_MEM"
    "--cosim-backend=$COSIM_BACKEND"
)

"${GEM5_DOCKER_CMD[@]}" >/dev/null

info "gem5 container '$GEM5_CONTAINER' started"

# ==================================================================
# Step 2: Wait for gem5 cosim socket to be ready
# ==================================================================

step "Waiting for gem5 to initialize (timeout: ${GEM5_TIMEOUT}s)..."

ELAPSED=0
if [[ "$COSIM_BACKEND" == "vfio-user" ]]; then
    READY_PATTERN="MI300XVfioUser: listening"
else
    READY_PATTERN="MI300XGem5Cosim: listening"
fi

while true; do
    if docker logs "$GEM5_CONTAINER" 2>&1 | grep -q "$READY_PATTERN"; then
        info "gem5 cosim socket ready (${ELAPSED}s, backend=$COSIM_BACKEND)"
        break
    fi

    # Check container still running
    if [[ "$(docker inspect -f '{{.State.Running}}' "$GEM5_CONTAINER" 2>/dev/null)" != "true" ]]; then
        echo ""
        error "gem5 container exited unexpectedly. Logs:\n$(docker logs "$GEM5_CONTAINER" 2>&1 | tail -20)"
    fi

    sleep 2
    ELAPSED=$((ELAPSED + 2))
    if [[ $ELAPSED -ge $GEM5_TIMEOUT ]]; then
        error "gem5 did not become ready in ${GEM5_TIMEOUT}s.\n  Logs: docker logs $GEM5_CONTAINER"
    fi

    # Progress indicator
    if (( ELAPSED % 10 == 0 )); then
        echo -n "."
    fi
done

# ==================================================================
# Step 3: Start QEMU
# ==================================================================

KCMDLINE="console=ttyS0,115200 root=/dev/vda1 drm_kms_helper.fbdev_emulation=0 modprobe.blacklist=amdgpu earlyprintk=serial,ttyS0,115200"
VRAM_BYTES=$((16 * 1024 * 1024 * 1024))

step "Starting QEMU (Q35 + KVM, backend=$COSIM_BACKEND)..."

echo "============================================================"
echo "  Machine:    Q35 + KVM"
echo "  Backend:    $COSIM_BACKEND"
echo "  CPUs:       $HOST_CPUS"
echo "  Memory:     $HOST_MEM"
echo "  Disk:       $(basename "$DISK_IMAGE")"
echo "  Kernel:     $(basename "$KERNEL")"
echo "  GPU socket: $SOCKET_PATH"
echo "  VRAM SHM:   $SHMEM_FILE"
echo "============================================================"
echo ""
echo "GPU driver loads automatically via cosim-gpu-setup.service (~40s)."
echo "After guest boots (auto-login as root), verify:"
echo "  rocm-smi          # should show device 0x74a0"
echo "  rocminfo          # should show gfx942"
echo ""
echo "Manual setup (if service is not installed):"
echo "  dd if=/root/roms/mi300.rom of=/dev/mem bs=1k seek=768 count=128"
echo "  modprobe amdgpu ip_block_mask=0x67 discovery=2 ras_enable=0"
echo ""
if [[ -n "$SHARE_DIR" ]]; then
    echo "Shared directory: $SHARE_DIR"
    echo "  In guest, run:"
    echo "  mount -t 9p -o trans=virtio,version=9p2000.L cosim_share /mnt"
    echo ""
fi
echo "Press Ctrl-A X to quit QEMU."
echo "============================================================"
echo ""

# Build QEMU command
QEMU_CMD=(
    "$QEMU_BIN"
    -machine q35
    -enable-kvm -cpu host
    -m "$HOST_MEM"
    -smp "$HOST_CPUS"
    -object "memory-backend-file,id=mem0,size=${HOST_MEM},mem-path=${SHMEM_HOST_FILE},share=on"
    -numa "node,memdev=mem0"
    -kernel "$KERNEL"
    -append "$KCMDLINE"
    -drive "file=$DISK_IMAGE,format=raw,if=virtio"
)

if [[ "$COSIM_BACKEND" == "vfio-user" ]]; then
    # Standard vfio-user protocol: QEMU's built-in vfio-user-pci device
    # Socket param requires JSON object format for SocketAddress type
    QEMU_CMD+=(-device "{\"driver\":\"vfio-user-pci\",\"socket\":{\"type\":\"unix\",\"path\":\"$SOCKET_PATH\"}}")
else
    # Legacy custom protocol: QEMU's mi300x-gem5 device
    QEMU_CMD+=(-device "mi300x-gem5,gem5-socket=$SOCKET_PATH,shmem-path=$SHMEM_FILE,vram-size=$VRAM_BYTES,romfile=$GPU_ROM")
fi

QEMU_CMD+=(
    -nographic
    -no-reboot
)

if [[ -n "$QEMU_TRACE" ]]; then
    QEMU_CMD+=(-trace "$QEMU_TRACE")
    info "QEMU trace: $QEMU_TRACE"
fi

if [[ -n "$SHARE_DIR" ]]; then
    QEMU_CMD+=(
        -fsdev "local,id=cosim_fs,path=${SHARE_DIR},security_model=none"
        -device "virtio-9p-pci,fsdev=cosim_fs,mount_tag=cosim_share"
    )
    info "Sharing host dir: $SHARE_DIR (mount: mount -t 9p -o trans=virtio cosim_share /mnt)"
fi

# Run QEMU in foreground with interactive serial console
exec "${QEMU_CMD[@]}"
