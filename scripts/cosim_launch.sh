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

# ---- Shared library ----

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COSIM_DIR="$(dirname "$SCRIPT_DIR")"

# shellcheck disable=SC1091
source "${SCRIPT_DIR}/cosim_lib.sh"

# ---- Run-ID ----

COSIM_RUN_ID="${COSIM_RUN_ID:-$(generate_run_id)}"
export COSIM_RUN_ID

# ---- Path defaults ----
GEM5_DIR="${COSIM_DIR}/gem5"
RESOURCES_DIR="${COSIM_DIR}/gem5-resources"

GEM5_BIN="${GEM5_DIR}/build/VEGA_X86/gem5.opt"
# shellcheck disable=SC2034
GEM5_CONFIG="${GEM5_DIR}/configs/example/gpufs/mi300_cosim.py"
GEM5_DOCKER_IMAGE="${GEM5_DOCKER_IMAGE:-gem5-run:local}"
GEM5_CONTAINER="$(cosim_container_name "$COSIM_RUN_ID")"

QEMU_BIN="${COSIM_DIR}/qemu/build/qemu-system-x86_64"
DISK_IMAGE="${RESOURCES_DIR}/src/x86-ubuntu-gpu-ml/disk-image/x86-ubuntu-rocm70"
KERNEL="${RESOURCES_DIR}/src/x86-ubuntu-gpu-ml/vmlinux-rocm70"
GPU_ROM="${RESOURCES_DIR}/src/x86-ubuntu-gpu-ml/files/mi300.rom"

SOCKET_PATH="/tmp/gem5-mi300x-${COSIM_RUN_ID}.sock"
SHMEM_PATH="/mi300x-vram-${COSIM_RUN_ID}"
SHMEM_HOST_PATH="/cosim-guest-ram-${COSIM_RUN_ID}"

HOST_MEM="8G"
HOST_CPUS="4"
VRAM_SIZE="16GiB"
NUM_CUS="40"
GEM5_DEBUG=""
GEM5_TIMEOUT=120
QEMU_TRACE=""
SHARE_DIR=""
COSIM_BACKEND="vfio-user"
NUM_GPUS="1"
FORCE_CLEAN=""
FORCE_CLEAN_CONFIRM=""

SESSION_DIR="/tmp/cosim-${COSIM_RUN_ID}.session"
SCREEN_LOG="/tmp/cosim-${COSIM_RUN_ID}.log"
ARTIFACT_DIR="${COSIM_DIR}/artifacts/standalone/${COSIM_RUN_ID}"
COSIM_FAILURE_CATEGORY=""
COSIM_SECONDARY_STATUS=""

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
  --num-gpus N            Number of GPU instances (default: 1)
  --timeout SECS          gem5 init timeout (default: 120)
  --force-clean           List orphaned cosim resources (dry-run)
  --confirm               With --force-clean, actually delete orphans
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
        --num-gpus)      NUM_GPUS="$2";         shift 2 ;;
        --timeout)       GEM5_TIMEOUT="$2";     shift 2 ;;
        --force-clean)   FORCE_CLEAN=1;         shift ;;
        --confirm)       FORCE_CLEAN_CONFIRM=1; shift ;;
        -h|--help)       usage ;;
        *)               echo "Unknown option: $1"; usage ;;
    esac
done

# Handle --force-clean mode
if [[ -n "$FORCE_CLEAN" ]]; then
    info "Force-clean mode (run-ID: $COSIM_RUN_ID)"
    if [[ -n "$FORCE_CLEAN_CONFIRM" ]]; then
        warn "Deleting orphaned cosim resources..."
        force_clean_orphans "true"
    else
        info "Dry-run: listing orphaned cosim resources..."
        force_clean_orphans "false"
    fi
    exit 0
fi

# ---- Multi-GPU validation ----

if [[ "$NUM_GPUS" -lt 1 ]]; then
    error "--num-gpus must be >= 1"
fi
if [[ "$NUM_GPUS" -gt 1 && "$COSIM_BACKEND" != "vfio-user" ]]; then
    error "Multi-GPU only supports vfio-user backend"
fi

# ---- Derived paths ----

SHMEM_HOST_FILE="/dev/shm${SHMEM_HOST_PATH}"

# Per-GPU socket and VRAM shmem paths
# Single GPU: /tmp/gem5-mi300x.sock, /dev/shm/mi300x-vram
# Multi GPU:  /tmp/gem5-mi300x-{0..N}.sock, /dev/shm/mi300x-vram-{0..N}
gpu_socket_path() {
    local gpu_id=$1
    if [[ "$NUM_GPUS" -eq 1 ]]; then
        echo "$SOCKET_PATH"
    else
        local stem="${SOCKET_PATH%.sock}"
        echo "${stem}-${gpu_id}.sock"
    fi
}

gpu_shmem_file() {
    local gpu_id=$1
    if [[ "$NUM_GPUS" -eq 1 ]]; then
        echo "/dev/shm${SHMEM_PATH}"
    else
        echo "/dev/shm${SHMEM_PATH}-${gpu_id}"
    fi
}

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

# ---- Session and manifest setup ----

mkdir -p "$SESSION_DIR"
manifest_init "$SESSION_DIR"

manifest_add "runtime" "container" "$GEM5_CONTAINER"
manifest_add "runtime" "shmem" "$SHMEM_HOST_FILE"
for ((g=0; g<NUM_GPUS; g++)); do
    manifest_add "runtime" "shmem" "$(gpu_shmem_file "$g")"
    manifest_add "runtime" "socket" "$(gpu_socket_path "$g")"
done
manifest_add "runtime" "directory" "$SESSION_DIR"
manifest_add "artifact" "directory" "$ARTIFACT_DIR"

# ---- Cleanup handler ----

# shellcheck disable=SC2317
cleanup() {
    local exit_code="${1:-$?}"
    echo ""

    # If runner signaled normal completion, treat as test_pass regardless
    if [[ -f "/tmp/cosim-test-done-${COSIM_RUN_ID}" ]]; then
        rm -f "/tmp/cosim-test-done-${COSIM_RUN_ID}"
        COSIM_FAILURE_CATEGORY="$COSIM_CAT_TEST_PASS"
    elif [[ -z "$COSIM_FAILURE_CATEGORY" ]]; then
        if [[ "$exit_code" -eq 0 ]]; then
            COSIM_FAILURE_CATEGORY="$COSIM_CAT_TEST_PASS"
        else
            COSIM_FAILURE_CATEGORY="$COSIM_CAT_INFRA_UNKNOWN"
        fi
    fi

    # Write category to a file outside session dir (session dir is deleted during cleanup)
    echo "$COSIM_FAILURE_CATEGORY" > "/tmp/cosim-launcher-category-${COSIM_RUN_ID}.txt" 2>/dev/null || true

    if [[ "$COSIM_FAILURE_CATEGORY" != "$COSIM_CAT_TEST_PASS" ]]; then
        info "Capturing diagnostic artifacts (category: $COSIM_FAILURE_CATEGORY)..."
        capture_artifacts "$ARTIFACT_DIR" "$GEM5_CONTAINER" "$SCREEN_LOG" \
            "$COSIM_RUN_ID" "$COSIM_FAILURE_CATEGORY"
    fi

    info "Shutting down co-simulation (run-ID: $COSIM_RUN_ID)..."
    cleanup_from_manifest "$GEM5_CONTAINER"

    if verify_cleanup 10 "$GEM5_CONTAINER"; then
        info "Teardown verified."
    else
        COSIM_SECONDARY_STATUS="$COSIM_CAT_CLEANUP_FAIL"
        warn "Teardown verification failed: some resources may remain."
    fi

    info "Run: $COSIM_RUN_ID | Category: $COSIM_FAILURE_CATEGORY${COSIM_SECONDARY_STATUS:+ | Secondary: $COSIM_SECONDARY_STATUS}"
}
trap 'cleanup' EXIT
trap 'COSIM_FAILURE_CATEGORY="$COSIM_CAT_INTERRUPT"; exit 130' INT TERM

# ---- Preflight audit ----

run_preflight_audit | tee "${SESSION_DIR}/preflight.log"

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
    "--num-gpus=$NUM_GPUS"
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

# For multi-GPU, wait until all N bridges report "listening"
EXPECTED_READY_COUNT="$NUM_GPUS"

while true; do
    READY_COUNT=$(docker logs "$GEM5_CONTAINER" 2>&1 | grep -c "$READY_PATTERN" || true)
    if [[ "$READY_COUNT" -ge "$EXPECTED_READY_COUNT" ]]; then
        info "gem5 cosim ready: $READY_COUNT/$EXPECTED_READY_COUNT GPU(s) (${ELAPSED}s, backend=$COSIM_BACKEND)"
        break
    fi

    # Check container still running
    if [[ "$(docker inspect -f '{{.State.Running}}' "$GEM5_CONTAINER" 2>/dev/null)" != "true" ]]; then
        echo ""
        COSIM_FAILURE_CATEGORY="$COSIM_CAT_GEM5_EXIT"
        error "gem5 container exited unexpectedly. Logs:\n$(docker logs "$GEM5_CONTAINER" 2>&1 | tail -20)"
    fi

    sleep 2
    ELAPSED=$((ELAPSED + 2))
    if [[ $ELAPSED -ge $GEM5_TIMEOUT ]]; then
        COSIM_FAILURE_CATEGORY="$COSIM_CAT_GEM5_INIT_TIMEOUT"
        error "gem5 did not become ready in ${GEM5_TIMEOUT}s.\n  Logs: docker logs $GEM5_CONTAINER"
    fi

    # Progress indicator
    if (( ELAPSED % 10 == 0 )); then
        echo -n "."
    fi
done

# ==================================================================
# Step 2.5: Pre-launch health check
# ==================================================================

step "Running pre-launch health check..."

parse_size_bytes() {
    local val="$1"
    local num="${val%%[GgMmKkTt]*}"
    local suffix="${val##*[0-9]}"
    case "${suffix,,}" in
        gib|g) echo $((num * 1024 * 1024 * 1024)) ;;
        mib|m) echo $((num * 1024 * 1024)) ;;
        kib|k) echo $((num * 1024)) ;;
        tib|t) echo $((num * 1024 * 1024 * 1024 * 1024)) ;;
        *)     echo "$num" ;;
    esac
}

EXPECTED_VRAM_BYTES="$(parse_size_bytes "$VRAM_SIZE")"
EXPECTED_RAM_BYTES="$(parse_size_bytes "$HOST_MEM")"

HEALTH_MSG=""
for ((g=0; g<NUM_GPUS; g++)); do
    if HEALTH_MSG="$(check_readiness \
            "$(gpu_socket_path "$g")" \
            "$(gpu_shmem_file "$g")" \
            "$SHMEM_HOST_FILE" \
            "$GEM5_CONTAINER" \
            "$EXPECTED_VRAM_BYTES" \
            "$EXPECTED_RAM_BYTES")"; then
        info "Health check GPU $g passed."
    else
        COSIM_FAILURE_CATEGORY="$COSIM_CAT_READINESS_FAIL"
        error "Pre-launch health check failed (GPU $g): $HEALTH_MSG"
    fi
done

# ==================================================================
# Step 3: Start QEMU
# ==================================================================

KCMDLINE="console=ttyS0,115200 root=/dev/vda1 drm_kms_helper.fbdev_emulation=0 modprobe.blacklist=amdgpu earlyprintk=serial,ttyS0,115200"
VRAM_BYTES=$((16 * 1024 * 1024 * 1024))

step "Starting QEMU (Q35 + KVM, backend=$COSIM_BACKEND)..."

echo "============================================================"
echo "  Run-ID:     $COSIM_RUN_ID"
echo "  Machine:    Q35 + KVM"
echo "  Backend:    $COSIM_BACKEND"
echo "  Num GPUs:   $NUM_GPUS"
echo "  CPUs:       $HOST_CPUS"
echo "  Memory:     $HOST_MEM"
echo "  Disk:       $(basename "$DISK_IMAGE")"
echo "  Kernel:     $(basename "$KERNEL")"
for ((g=0; g<NUM_GPUS; g++)); do
    echo "  GPU $g:"
    echo "    Socket:   $(gpu_socket_path "$g")"
    echo "    VRAM SHM: $(gpu_shmem_file "$g")"
done
echo "============================================================"
echo ""
echo "GPU driver loads automatically via cosim-gpu-setup.service (~40s)."
echo "After guest boots (auto-login as root), verify:"
echo "  rocm-smi          # should show device 0x74a0"
echo "  rocminfo          # should show gfx942"
echo ""
echo "Manual setup (if service is not installed):"
echo "  dd if=/root/roms/mi300.rom of=/dev/mem bs=1k seek=768 count=128"
echo "  modprobe amdgpu ip_block_mask=0x67 ppfeaturemask=0 dpm=0 audio=0 ras_enable=0 discovery=2"
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
    -netdev "user,id=net0,hostfwd=tcp::2222-:22"
    -device "virtio-net-pci,netdev=net0"
)

if [[ "$COSIM_BACKEND" == "vfio-user" ]]; then
    # Standard vfio-user protocol: one vfio-user-pci device per GPU
    for ((g=0; g<NUM_GPUS; g++)); do
        local_sock="$(gpu_socket_path "$g")"
        QEMU_CMD+=(-device "{\"driver\":\"vfio-user-pci\",\"socket\":{\"type\":\"unix\",\"path\":\"$local_sock\"}}")
    done
else
    # Legacy custom protocol: single GPU only
    local_shmem="$(gpu_shmem_file 0)"
    QEMU_CMD+=(-device "mi300x-gem5,gem5-socket=$SOCKET_PATH,shmem-path=$local_shmem,vram-size=$VRAM_BYTES,romfile=$GPU_ROM")
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

# Run QEMU in foreground — do NOT exec, so the EXIT trap runs on QEMU exit
if "${QEMU_CMD[@]}"; then
    QEMU_RC=0
else
    QEMU_RC=$?
    COSIM_FAILURE_CATEGORY="${COSIM_FAILURE_CATEGORY:-$COSIM_CAT_QEMU_EXIT}"
fi
exit $QEMU_RC
