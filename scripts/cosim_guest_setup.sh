#!/bin/bash
# ==========================================================================
# Guest-side setup script for MI300X co-simulation
#
# Run this INSIDE the QEMU guest after booting to:
#   1. Load the AMD GPU VGA ROM
#   2. Load the amdgpu kernel module
#   3. Verify the GPU is recognized by ROCm
#
# This mirrors the setup from gem5's GPUFS runscript (mi300.py) but
# adapted for the QEMU Q35 co-simulation environment.
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

# ---- Step 1: VGA ROM ----
echo "[1/4] Loading VGA ROM..."
if [ -f /root/roms/mi300.rom ]; then
    dd if=/root/roms/mi300.rom of=/dev/mem bs=1k seek=768 count=128 2>/dev/null
    echo "  VGA ROM loaded."
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
echo "[3/4] Loading amdgpu kernel module..."
if [ -f /home/gem5/load_amdgpu.sh ]; then
    # Newer disk images have a dedicated load script
    sh /home/gem5/load_amdgpu.sh
elif [ -f "/lib/modules/$(uname -r)/updates/dkms/amdgpu.ko" ]; then
    modprobe -v amdgpu \
        ip_block_mask=0x67 \
        ras_enable=0 \
        discovery=2
else
    echo "  ERROR: amdgpu.ko not found for kernel $(uname -r)"
    echo "  Make sure the disk image was built with the GPU ML packer config."
    exit 1
fi

echo "  amdgpu module loaded."

# ---- Step 4: Verify ----
echo "[4/4] Verifying GPU setup..."

echo ""
echo "--- lspci (GPU) ---"
lspci | grep -i "amd\|display\|vga" || echo "  (no GPU found in lspci)"

echo ""
echo "--- dmesg (amdgpu) ---"
dmesg | grep -i amdgpu | tail -20

echo ""
if command -v rocm-smi &>/dev/null; then
    echo "--- rocm-smi ---"
    rocm-smi || true
fi

if command -v rocminfo &>/dev/null; then
    echo ""
    echo "--- rocminfo (agents) ---"
    rocminfo 2>/dev/null | head -40 || true
fi

echo ""
echo "=== MI300X setup complete ==="
echo ""
echo "You can now run GPU workloads:"
echo "  hipcc --amdgpu-target=gfx942 square.cpp -o square && ./square"
echo "  python3 softmax.py  # (PyTorch + Triton)"
