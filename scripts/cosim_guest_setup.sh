#!/bin/bash
# ==========================================================================
# Guest-side setup script for MI300X co-simulation
#
# Run this INSIDE the QEMU guest after booting to:
#   1. Load the AMD GPU VGA ROM (for each GPU)
#   2. Load the amdgpu kernel module
#   3. Verify GPU(s) are recognized by ROCm
#
# Supports multi-GPU: automatically detects all AMD GPU PCI devices
# and loads ROM for each one.
#
# Usage (inside QEMU guest):
#   sudo bash /path/to/cosim_guest_setup.sh
# ==========================================================================

set -e

echo "=== MI300X Co-simulation Guest Setup ==="

# ---- Environment ----
export LD_LIBRARY_PATH=/opt/rocm/lib:${LD_LIBRARY_PATH:-}
export HSA_ENABLE_INTERRUPT=0
export HCC_AMDGPU_TARGET=gfx942

# ---- Detect GPU count ----
GPU_COUNT=$(lspci -d 1002: | grep -c "Display\|VGA\|3D" || echo 0)
if [ "$GPU_COUNT" -eq 0 ]; then
    # Also try matching by known device IDs
    GPU_COUNT=$(lspci -d 1002: | wc -l)
fi
echo "Detected $GPU_COUNT AMD GPU device(s)"

# ---- Step 1: VGA ROM ----
echo "[1/4] Loading VGA ROM..."
if [ -f /root/roms/mi300.rom ]; then
    # ROM needs to be loaded to legacy VGA address 0xC0000 (768k).
    # For multi-GPU, only the first GPU uses the legacy VGA ROM location.
    # Additional GPUs get their ROM via PCI expansion ROM BAR.
    dd if=/root/roms/mi300.rom of=/dev/mem bs=1k seek=768 count=128 2>/dev/null
    echo "  VGA ROM loaded for primary GPU."
else
    echo "  WARNING: /root/roms/mi300.rom not found, skipping ROM load."
    echo "  Some GPU initialization may fail."
fi

# ---- Step 2: IP Discovery firmware ----
echo "[2/4] Setting up IP discovery firmware..."
if [ -e /usr/lib/firmware/amdgpu/mi300_discovery ]; then
    rm -f /usr/lib/firmware/amdgpu/ip_discovery.bin
    ln -s /usr/lib/firmware/amdgpu/mi300_discovery \
          /usr/lib/firmware/amdgpu/ip_discovery.bin
    echo "  IP discovery firmware linked."
else
    echo "  Using default IP discovery firmware."
fi

# ---- Step 3: Load amdgpu driver ----
# NOTE: Do NOT delegate to /home/gem5/load_amdgpu.sh — that script uses
# ip_block_mask=0x6f (PSP enabled) which is for standalone gem5 only.
echo "[3/4] Loading amdgpu kernel module..."
AMDGPU_ARGS=(ip_block_mask=0x67 ppfeaturemask=0 dpm=0 audio=0 ras_enable=0 discovery=2)

# Kernel cmdline modprobe.blacklist=amdgpu creates a runtime blacklist that
# causes modprobe to silently skip the module (exit 0 without loading).
rm -f /run/modprobe.d/*blacklist* 2>/dev/null

if modprobe -v amdgpu "${AMDGPU_ARGS[@]}"; then
    echo "  amdgpu loaded (modprobe)"
elif insmod "/lib/modules/$(uname -r)/updates/dkms/amdgpu.ko.zst" "${AMDGPU_ARGS[@]}" 2>/dev/null; then
    echo "  amdgpu loaded (insmod .ko.zst)"
elif insmod "/lib/modules/$(uname -r)/updates/dkms/amdgpu.ko" "${AMDGPU_ARGS[@]}" 2>/dev/null; then
    echo "  amdgpu loaded (insmod .ko)"
else
    echo "  ERROR: failed to load amdgpu for kernel $(uname -r)"
    echo "  Make sure the disk image was built with the GPU ML packer config."
    exit 1
fi

echo "  amdgpu module loaded."

# ---- Step 4: Verify ----
echo "[4/4] Verifying GPU setup..."

echo ""
echo "--- lspci (GPU) ---"
lspci -d 1002: || echo "  (no AMD GPU found in lspci)"

echo ""
echo "--- dmesg (amdgpu) ---"
dmesg | grep -i amdgpu | tail -30

echo ""
echo "--- DRM render nodes ---"
ls -la /dev/dri/render* 2>/dev/null || echo "  (no render nodes found)"

INITIALIZED_COUNT=0
if [ -d /sys/class/drm ]; then
    for card in /sys/class/drm/card[0-9]*; do
        if [ -d "$card/device" ] && [ -f "$card/device/vendor" ]; then
            vendor=$(cat "$card/device/vendor" 2>/dev/null)
            if [ "$vendor" = "0x1002" ]; then
                INITIALIZED_COUNT=$((INITIALIZED_COUNT + 1))
            fi
        fi
    done
fi
echo ""
echo "Initialized AMD GPUs: $INITIALIZED_COUNT / $GPU_COUNT"

if command -v rocm-smi &>/dev/null; then
    echo ""
    echo "--- rocm-smi ---"
    rocm-smi || true
fi

if command -v rocminfo &>/dev/null; then
    echo ""
    echo "--- rocminfo (agents) ---"
    rocminfo 2>/dev/null | head -60 || true
fi

echo ""
echo "=== MI300X setup complete ($INITIALIZED_COUNT GPU(s)) ==="
echo ""
echo "You can now run GPU workloads:"
echo "  hipcc --amdgpu-target=gfx942 square.cpp -o square && ./square"
if [ "$INITIALIZED_COUNT" -gt 1 ]; then
    echo "  HIP_VISIBLE_DEVICES=0 ./square   # run on GPU 0"
    echo "  HIP_VISIBLE_DEVICES=1 ./square   # run on GPU 1"
fi
